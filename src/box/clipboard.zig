const std = @import("std");

pub fn buildOsc52(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(content.len);
    const encoded_buf = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded_buf);
    const encoded = std.base64.standard.Encoder.encode(encoded_buf, content);

    const result = try std.fmt.allocPrint(allocator, "\x1b]52;c;{s}\x1b\\", .{encoded});
    allocator.free(encoded_buf);
    return result;
}
