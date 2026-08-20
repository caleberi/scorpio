const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try @import("tools/pack_blog.zig").main(init);
}
