const zstd = @import("std");

pub fn Point(comptime T: type) type {
    return struct { x: T, y: T };
}

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn center(self: Rect) Point(f32) {
        return .{ .x = self.x + self.w / 2, .y = self.y + self.h / 2 };
    }
};

/// Affine draw transform. Identity is zeros / ones as documented in RENDER.md.
pub const Transform = struct {
    tx: f32 = 0,
    ty: f32 = 0,
    sx: f32 = 1,
    sy: f32 = 1,
    rotate_deg: f32 = 0,
    opacity: f32 = 1,

    pub const identity: Transform = .{};

    pub fn merge(self: Transform, other: Transform) Transform {
        return .{
            .tx = self.tx + other.tx,
            .ty = self.ty + other.ty,
            .sx = self.sx * other.sx,
            .sy = self.sy * other.sy,
            .rotate_deg = self.rotate_deg + other.rotate_deg,
            .opacity = self.opacity * other.opacity,
        };
    }
};

const testing = zstd.testing;

test "rect center and identity transform" {
    const r = Rect{ .x = 10, .y = 20, .w = 100, .h = 40 };
    const c = r.center();
    try testing.expectEqual(@as(f32, 60), c.x);
    try testing.expectEqual(@as(f32, 40), c.y);
    try testing.expectEqual(@as(f32, 1), Transform.identity.sx);
}
