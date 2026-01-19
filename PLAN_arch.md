# Hexa Session Management Architecture

## Overview: The Flipped Model

**Key insight**: Process stays alive as long as someone holds the PTY master fd. We can pass fds between processes. We don't need to transfer scrollback.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ses (PTY holder)                              │
│                         /src/ses/                                    │
│                                                                      │
│  MINIMAL - just keeps processes alive:                               │
│  - Holds PTY master file descriptors                                 │
│  - Tracks child PIDs                                                 │
│  - Passes fds to mux via SCM_RIGHTS                                  │
│  - That's it! No VT, no scrollback, no session structure             │
│                                                                      │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                 Unix Socket: /run/user/1000/hexa/ses.sock
                 (fd passing via SCM_RIGHTS)
                              │
            ┌─────────────────┼─────────────────┐
            │                 │                 │
       ┌────▼────┐      ┌─────▼────┐      ┌─────▼────┐
       │   mux   │      │   mux    │      │   pop    │
       │ (OWNER) │      │ (OWNER)  │      │ (prompt) │
       │         │      │          │      │          │
       └─────────┘      └──────────┘      └──────────┘

mux OWNS:
- Session structure (tabs, floats, splits)
- VT state (scrollback, screen buffer)
- Rendering
- All the logic
```

---

## What Each Component Owns

### ses (minimal PTY holder)

```zig
// src/ses/state.zig - VERY SIMPLE

const Pane = struct {
    uuid: UUID,
    master_fd: fd_t,      // THE IMPORTANT BIT - keeps process alive
    child_pid: pid_t,

    // For sticky pwd floats
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    state: enum { attached, half_orphaned, orphaned },

    // That's ALL. No VT, no scrollback, no env, no structure
};

const SesState = struct {
    panes: HashMap(UUID, Pane),
    // No sessions, no tabs, no floats - mux owns those
};
```

### mux (owns everything else)

```zig
// src/mux/state.zig - FULL OWNER

const Pane = struct {
    uuid: UUID,
    fd: fd_t,             // Received from ses
    vt: VT,               // Scrollback lives HERE in mux
    pwd: []const u8,
    env: StringHashMap([]const u8),
    pop_state: ?PopState,
};

const Session = struct {
    uuid: UUID,
    name: []const u8,
    tabs: ArrayList(Tab),
    floats: ArrayList(Float),
    active_tab: usize,
};

// mux owns the ENTIRE hierarchy
```

---

## Crash Scenarios

### mux crashes (PROCESSES SURVIVE!)

```
1. mux crashes or user closes terminal

2. ses still holds all PTY master fds
   └── Processes keep running! (shell, vim, whatever)

3. User restarts mux
   └── mux connects to ses
   └── mux sends: {"type":"reconnect","panes":["abc123","def456"]}

4. ses passes fds back via SCM_RIGHTS
   └── mux receives master_fd for each pane

5. mux rebuilds fresh VT state
   └── Scrollback is LOST (empty screen)
   └── But process is ALIVE!

6. User types "ls" → output appears → shell works!
   └── From user perspective: "blank screen but my shell is still there"
```

### ses crashes (processes die, structure survives)

```
1. ses crashes
   └── Kernel closes all master fds
   └── All child processes receive SIGHUP and die

2. mux detects disconnect
   └── mux shows: "PTY server crashed. Restarting..."

3. mux restarts ses
   └── mux recreates panes (spawns new shells)
   └── Session STRUCTURE preserved (tabs, floats, layout)
   └── Scrollback preserved (was in mux memory)

4. User sees: same layout, but shells restarted
```

### Comparison

| Crash | Processes | Scrollback | Structure |
|-------|-----------|------------|-----------|
| mux crashes | ✅ ALIVE | ❌ Lost | ❌ Lost (but can persist to disk) |
| ses crashes | ❌ Dead | ✅ Kept | ✅ Kept |

---

## Hierarchy (lives in mux)

```
mux
├── Sessions[]
│     └── Session (UUID)
│           ├── name, created_at
│           ├── active_tab: usize
│           │
│           ├── Tabs[] ─────────────────────┐
│           │     └── Tab (UUID)            │
│           │           ├── name            │  SAME
│           │           ├── state           │  LEVEL
│           │           └── layout: SplitTree
│           │                 └── Split (UUID)
│           │                       └── pane_uuid
│           │                                │
│           └── Floats[] ───────────────────┘
│                 └── Float (UUID)
│                       ├── pane_uuid
│                       ├── position (x%, y%)
│                       ├── size (w%, h%)
│                       ├── state: visible|hidden
│                       ├── pwd_bound: ?[]const u8
│                       └── sticky: bool
│
└── Panes (local state)
      └── Pane
            ├── uuid
            ├── fd (from ses)
            ├── vt (scrollback HERE)
            ├── pwd, env
            └── pop_state
```

---

## Pane States (managed by ses)

```
┌─────────────────┐     ┌───────────────────┐     ┌─────────────────┐
│    ATTACHED     │     │   HALF-ORPHANED   │     │    ORPHANED     │
│                 │     │                   │     │                 │
│ mux connected   │     │ PWD sticky float  │     │ Fully detached  │
│ Has fd owner    │     │ mux exited        │     │ Manual suspend  │
│                 │     │ Waiting for       │     │ Any mux can     │
│                 │     │ same pwd + key    │     │ adopt           │
└────────┬────────┘     └─────────┬─────────┘     └────────┬────────┘
         │                        │                        │
         │  mux disconnects       │  mux connects          │
         │  (sticky=true)         │  same pwd+key          │
         ├───────────────────────>│                        │
         │                        ├───────────────────────>│
         │                        │  adopts                │
         │<───────────────────────┤                        │
         │                                                 │
         │  manual suspend (Alt+Z)                         │
         ├────────────────────────────────────────────────>│
         │                                                 │
         │              mux attach-pane                    │
         │<────────────────────────────────────────────────┤
```

---

## Sticky PWD Floats

### Config

```json
{
  "floats": [
    {
      "key": "1",
      "pwd": true,
      "sticky": true,
      "width_percent": 60,
      "height_percent": 60
    }
  ]
}
```

### Flow

```
1. mux in ~/code/bloxs, user presses Alt+1
   └── mux asks ses: create_pane(sticky_pwd="~/code/bloxs", sticky_key='1')
   └── ses spawns shell, returns uuid + fd
   └── mux creates Float with pane

2. User closes terminal (mux disconnects)
   └── mux tells ses: disconnect(panes=["abc123"])
   └── ses marks pane as half_orphaned (keeps fd!)
   └── Shell keeps running

3. Later: new mux in ~/code/bloxs, user presses Alt+1
   └── mux asks ses: find_sticky(pwd="~/code/bloxs", key='1')
   └── ses finds half_orphaned pane abc123
   └── ses passes fd to mux via SCM_RIGHTS
   └── ses marks pane as attached
   └── mux creates fresh VT, receives fd
   └── User's shell is back! (no scrollback, but process alive)

4. User manually suspends (Alt+Z)
   └── mux tells ses: orphan_pane("abc123")
   └── ses marks as fully orphaned
   └── mux creates NEW pane (becomes the sticky one)
```

---

## Socket Protocol

### Socket Path
```
/run/user/$UID/hexa/ses.sock
```

### mux → ses

```json
// Create new pane
{"type":"create_pane","sticky_pwd":"/home/user","sticky_key":"1"}

// Find sticky pane (for pwd floats)
{"type":"find_sticky","pwd":"/home/user","key":"1"}

// Reconnect to existing panes after mux restart
{"type":"reconnect","pane_uuids":["abc123","def456"]}

// Disconnect (mux exiting)
{"type":"disconnect","pane_uuids":["abc123"]}

// Orphan a pane (manual suspend)
{"type":"orphan_pane","uuid":"abc123"}

// List orphaned panes
{"type":"list_orphaned"}

// Adopt orphaned pane
{"type":"adopt_pane","uuid":"abc123"}

// Kill pane
{"type":"kill_pane","uuid":"abc123"}
```

### ses → mux

```json
// Pane created (includes fd via SCM_RIGHTS)
{"type":"pane_created","uuid":"abc123","pid":12345}
// fd sent as ancillary data

// Pane found (for sticky lookup)
{"type":"pane_found","uuid":"abc123","pid":12345}
// fd sent as ancillary data

// Pane not found
{"type":"pane_not_found"}

// Reconnect response (multiple fds)
{"type":"reconnected","panes":[{"uuid":"abc123","pid":12345},{"uuid":"def456","pid":12346}]}
// fds sent as ancillary data array

// Pane exited
{"type":"pane_exited","uuid":"abc123","exit_code":0}

// Orphaned panes list
{"type":"orphaned_panes","panes":[{"uuid":"abc123","sticky_pwd":"/home/user","sticky_key":"1"}]}
```

---

## FD Passing (SCM_RIGHTS)

The magic that makes this work:

```zig
// ses sends fd to mux
pub fn sendFd(socket: fd_t, fd_to_send: fd_t, msg: []const u8) !void {
    var iov = [_]posix.iovec{.{
        .base = msg.ptr,
        .len = msg.len,
    }};

    var cmsg_buf: [CMSG_SPACE(@sizeOf(fd_t))]u8 align(@alignOf(cmsghdr)) = undefined;

    var msgh = posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    var cmsg = CMSG_FIRSTHDR(&msgh);
    cmsg.level = posix.SOL.SOCKET;
    cmsg.type = SCM_RIGHTS;
    cmsg.len = CMSG_LEN(@sizeOf(fd_t));
    @memcpy(CMSG_DATA(cmsg), std.mem.asBytes(&fd_to_send));

    _ = try posix.sendmsg(socket, &msgh, 0);
}

// mux receives fd from ses
pub fn receiveFd(socket: fd_t, buf: []u8) !struct { fd: fd_t, len: usize } {
    var iov = [_]posix.iovec{.{
        .base = buf.ptr,
        .len = buf.len,
    }};

    var cmsg_buf: [CMSG_SPACE(@sizeOf(fd_t))]u8 align(@alignOf(cmsghdr)) = undefined;

    var msgh = posix.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_buf.len,
        .flags = 0,
    };

    const len = try posix.recvmsg(socket, &msgh, 0);

    var cmsg = CMSG_FIRSTHDR(&msgh);
    const fd = std.mem.bytesToValue(fd_t, CMSG_DATA(cmsg));

    return .{ .fd = fd, .len = len };
}
```

---

## pop Integration

Pop talks to mux (not ses) since mux owns the session structure.

### Environment Variables (set by mux when spawning via ses)

| Variable | Example | Purpose |
|----------|---------|---------|
| `HEXA_MUX_SOCKET` | `/run/user/1000/hexa/mux-xxx.sock` | mux socket |
| `HEXA_PANE_UUID` | `abc123` | This pane's UUID |
| `HEXA_SESSION` | `work` | Session name |
| `BOX` | `1` | Running in hexa |

### Message Flow

```
pop → mux: pane update with env
mux → pop: session context

(mux handles this, not ses - ses is too dumb)
```

---

## Data Structures

### ses (minimal)

```zig
// src/ses/state.zig

const Pane = struct {
    uuid: [16]u8,
    master_fd: fd_t,
    child_pid: pid_t,
    state: enum { attached, half_orphaned, orphaned },
    sticky_pwd: ?[]const u8,
    sticky_key: ?u8,
    attached_to: ?ClientId,  // which mux owns this
    created_at: i64,
};

const SesState = struct {
    panes: std.AutoHashMap([16]u8, Pane),
    clients: std.ArrayList(Client),
    orphan_timeout_hours: u32 = 24,
};
```

### mux (full owner)

```zig
// src/mux/state.zig

const LocalPane = struct {
    uuid: [16]u8,
    fd: fd_t,              // received from ses
    vt: VT,                // scrollback HERE
    pid: pid_t,
    pwd: []const u8,
    env: std.StringHashMap([]const u8),
    pop_uuid: ?[16]u8,
    pop_last_update: i64,
};

const Tab = struct {
    uuid: [16]u8,
    name: []const u8,
    layout: SplitLayout,
    state: enum { active, inactive },
};

const Float = struct {
    uuid: [16]u8,
    pane_uuid: [16]u8,
    pos_x_pct: u8,
    pos_y_pct: u8,
    width_pct: u8,
    height_pct: u8,
    visible: bool,
    pwd_bound: ?[]const u8,
    sticky: bool,
    key: u8,
};

const Session = struct {
    uuid: [16]u8,
    name: []const u8,
    tabs: std.ArrayList(Tab),
    floats: std.ArrayList(Float),
    active_tab: usize,
};

const MuxState = struct {
    sessions: std.ArrayList(Session),
    active_session: usize,
    panes: std.AutoHashMap([16]u8, LocalPane),
    ses_socket: fd_t,
};
```

---

## Files to Create/Modify

### New: `/src/ses/`
- `main.zig` - ses daemon entry point (simple!)
- `state.zig` - Pane struct (minimal)
- `server.zig` - Unix socket server
- `fdpass.zig` - SCM_RIGHTS fd passing

### Modify: `/src/mux/`
- `main.zig` - Connect to ses, request fds
- `state.zig` - Own session structure, VT state
- `client.zig` - ses client connection + fd receiving
- Keep existing rendering, input handling

### New: `/src/core/`
- `ipc.zig` - Shared socket utilities, fd passing helpers
- `uuid.zig` - UUID generation

### Modify: `build.zig`
- Add `ses` executable

---

## Commands

```bash
# Normal usage
mux                          # Connect to ses (or start it), create/attach session

# Session management
mux ls                       # List sessions
mux attach -s <name>         # Attach to session
mux detach                   # Detach (Ctrl+Alt+D)

# Pane management
mux panes                    # List orphaned panes (asks ses)
mux attach-pane <uuid>       # Adopt orphaned pane
```

### Keybindings

| Key | Action |
|-----|--------|
| Alt+Z | Suspend pane (tell ses to orphan it) |
| Alt+Shift+Z | Show orphaned panes picker |
| Alt+D | Detach from session |
| Alt+1-9 | Toggle float (check ses for sticky first) |

---

## Verification

1. **Basic flow**: mux starts, ses starts, panes work
2. **mux crash recovery**: Kill mux, restart, processes still alive, can reconnect
3. **ses crash recovery**: Kill ses, mux restarts it, new shells spawned
4. **Sticky floats**: Exit mux, reopen in same pwd, adopts existing pane
5. **Manual orphan**: Alt+Z orphans, can attach elsewhere
6. **FD passing**: Verify fds transfer correctly via SCM_RIGHTS
7. **Timeout cleanup**: Orphaned panes cleaned up after timeout

---

## Design Decisions

1. **Session naming**: Auto-generate (e.g., "brave-fox"). User can rename.

2. **Multiple clients same session**: One active, others read-only.

3. **Orphaned pane lifetime**: 24 hour timeout (configurable).

4. **Scrollback on reconnect**: Lost. Fresh VT created. Process alive.

5. **ses auto-start**: First mux spawns ses if not running.

6. **Structure persistence**: mux can save/load session structure to disk (optional future feature).
