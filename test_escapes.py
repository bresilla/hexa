#!/usr/bin/env python3
"""
Comprehensive terminal escape sequence test script.
Run this inside hexa-mux to identify rendering issues.
"""

import sys
import time

pause_mode = "--pause" in sys.argv

def section(title):
    print(f"\n{'='*60}")
    print(f"  {title}")
    print(f"{'='*60}\n")

def end_section():
    if pause_mode:
        print("\n  [Press Enter for next section]")
        input()

def test(name, sequence):
    print(f"  {name}: {sequence}TEST\033[0m  ", end="")
    sys.stdout.flush()
    time.sleep(0.05)
    print("(should reset after)")

# Basic colors
section("BASIC FOREGROUND COLORS (30-37)")
for i in range(30, 38):
    test(f"Color {i}", f"\033[{i}m")
end_section()

section("BASIC BACKGROUND COLORS (40-47)")
for i in range(40, 48):
    test(f"Color {i}", f"\033[{i}m")
end_section()

section("BRIGHT FOREGROUND COLORS (90-97)")
for i in range(90, 98):
    test(f"Color {i}", f"\033[{i}m")

section("BRIGHT BACKGROUND COLORS (100-107)")
for i in range(100, 108):
    test(f"Color {i}", f"\033[{i}m")
end_section()

# 256 colors
section("256-COLOR FOREGROUND (38;5;N)")
for i in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]:
    test(f"FG 38;5;{i}", f"\033[38;5;{i}m")

print()
for i in [16, 21, 51, 87, 196, 208, 226, 231, 232, 255]:
    test(f"FG 38;5;{i}", f"\033[38;5;{i}m")

section("256-COLOR BACKGROUND (48;5;N)")
for i in [0, 1, 2, 3, 4, 5, 6, 7, 14, 21, 196, 226]:
    test(f"BG 48;5;{i}", f"\033[48;5;{i}m")
end_section()

# RGB colors
section("RGB FOREGROUND (38;2;R;G;B)")
test("Red", "\033[38;2;255;0;0m")
test("Green", "\033[38;2;0;255;0m")
test("Blue", "\033[38;2;0;0;255m")
test("Yellow", "\033[38;2;255;255;0m")
test("Cyan", "\033[38;2;0;255;255m")
test("Magenta", "\033[38;2;255;0;255m")
test("White", "\033[38;2;255;255;255m")
test("Gray", "\033[38;2;128;128;128m")

section("RGB BACKGROUND (48;2;R;G;B)")
test("Red BG", "\033[48;2;255;0;0m")
test("Green BG", "\033[48;2;0;255;0m")
test("Blue BG", "\033[48;2;0;0;255m")
end_section()

# Text attributes
section("TEXT ATTRIBUTES")
test("Bold", "\033[1m")
test("Dim/Faint", "\033[2m")
test("Italic", "\033[3m")
test("Underline", "\033[4m")
test("Blink", "\033[5m")
test("Inverse", "\033[7m")
test("Hidden", "\033[8m")
test("Strikethrough", "\033[9m")

section("COMBINED ATTRIBUTES")
test("Bold+Red", "\033[1;31m")
test("Bold+Italic+Blue", "\033[1;3;34m")
test("Underline+Green", "\033[4;32m")
test("Bold+Underline+Yellow", "\033[1;4;33m")
test("Inverse+Cyan", "\033[7;36m")

section("COMPLEX COMBINATIONS")
test("Bold+FG256+BG256", "\033[1;38;5;196;48;5;21m")
test("Italic+RGB FG", "\033[3;38;2;255;128;0m")
test("Underline+RGB BG", "\033[4;48;2;0;64;128m")

# Cursor movement
section("CURSOR MOVEMENT (watch for glitches)")
print("  Testing cursor save/restore...", end="")
sys.stdout.flush()
print("\033[s", end="")  # Save cursor
print("\033[5;10H", end="")  # Move to row 5, col 10
print("X", end="")
print("\033[u", end="")  # Restore cursor
print(" done")

# Erase sequences
section("ERASE SEQUENCES")
print("  Line with text: AAAA\033[KBBBB (K erases to end)")
print("  Line with text: CCCC\033[1KDDDD (1K erases to start)")
print("  Line with text: EEEE\033[2KFFFF (2K erases whole line)")

# OSC sequences
section("OSC SEQUENCES (may not be visible)")
print("  Setting window title...", end="")
print("\033]0;HEXA-MUX TEST\007", end="")
print(" done (check title bar)")

print("  Setting icon name...", end="")
print("\033]1;HEXA-ICON\007", end="")
print(" done")

# Alternate character sets
section("LINE DRAWING CHARACTERS")
print("  \033(0lqqqqqqqqqqqqqqqqqqqk\033(B")
print("  \033(0x                   x\033(B")
print("  \033(0x   Box Drawing     x\033(B")
print("  \033(0x                   x\033(B")
print("  \033(0mqqqqqqqqqqqqqqqqqqqj\033(B")

# Rapid output test
section("RAPID OUTPUT TEST")
print("  Rapid color switching: ", end="")
for i in range(20):
    print(f"\033[3{i%8}m█\033[0m", end="")
    sys.stdout.flush()
print()

print("  Rapid text: ", end="")
for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
    print(f"\033[1;3{ord(c)%8}m{c}\033[0m", end="")
    sys.stdout.flush()
print()

# Unicode test
section("UNICODE CHARACTERS")
print("  Basic Latin: ABCDEFGabcdefg")
print("  Accented: àéîõü ñ ç")
print("  Symbols: © ® ™ € £ ¥")
print("  Arrows: ← → ↑ ↓ ↔ ↕")
print("  Box drawing: ┌─┐│└┘├┤┬┴┼")
print("  Blocks: ░▒▓█▀▄▌▐")
print("  Math: ∑ ∏ √ ∞ ≠ ≤ ≥")
print("  Greek: αβγδεζηθ")
print("  Emoji: 😀 🎉 🚀 ⭐ (may not render)")

# Wide characters
section("WIDE CHARACTERS (CJK)")
print("  Chinese: 你好世界")
print("  Japanese: こんにちは")
print("  Korean: 안녕하세요")

# Stress test
section("STRESS TEST - MANY STYLE CHANGES")
for row in range(5):
    for col in range(40):
        fg = 31 + (row + col) % 7
        attr = 1 if (row + col) % 3 == 0 else 0
        print(f"\033[{attr};{fg}m#\033[0m", end="")
    print()

# SGR edge cases
section("SGR EDGE CASES")
test("Empty SGR", "\033[m")
test("Just 0", "\033[0m")
test("Multiple resets", "\033[0;0;0m")
test("Unknown attr 99", "\033[99m")
test("Very long", "\033[1;2;3;4;5;7;31;42m")

# CSI edge cases
section("CSI EDGE CASES")
print("  CSI with no params: \033[H(moved to home?)")
print("  CSI n (DSR): \033[6n (may see response)")
print("  CSI ?25l (hide cursor) then ?25h (show): ", end="")
print("\033[?25l", end="")
time.sleep(0.2)
print("\033[?25h", end="")
print("done")

# Final summary
section("TEST COMPLETE")
print("  If you saw garbled text or escape codes appearing as")
print("  literal characters like '38;5;14m', note which section")
print("  had the problem.")
print()
print("\033[1;32m  All tests finished!\033[0m")
print()
print("Press Enter to exit...")
input()
