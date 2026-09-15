const color = @import("color.zig");
const shape = @import("shape.zig");

pub const default_width: u32 = 1920;
pub const default_height: u32 = 1080;

pub const Canvas = struct {
    width: u32 = default_width,
    height: u32 = default_height,
    background: color.Color = color.Color.rgb(10, 13, 20),

    pub fn size(self: Canvas) shape.Point(u32) {
        return .{ .x = self.width, .y = self.height };
    }
};
