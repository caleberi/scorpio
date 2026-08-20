const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try @import("tools/prerun.zig").main(init);
}
