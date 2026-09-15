const zstd = @import("std");
const shape = @import("../components/shape.zig");

pub const Ease = enum {
    linear,
    ease,
    ease_in,
    ease_out,
    cubic_in,
    cubic_out,
    cubic_in_out,

    pub fn json(self: Ease) []const u8 {
        return switch (self) {
            .linear => "linear",
            .ease => "ease",
            .ease_in => "ease-in",
            .ease_out => "ease-out",
            .cubic_in => "cubic-in",
            .cubic_out => "cubic-out",
            .cubic_in_out => "cubic-in-out",
        };
    }

    pub fn parse(name: []const u8) Ease {
        if (zstd.ascii.eqlIgnoreCase(name, "ease-in")) return .ease_in;
        if (zstd.ascii.eqlIgnoreCase(name, "ease-out")) return .ease_out;
        if (zstd.ascii.eqlIgnoreCase(name, "cubic-in")) return .cubic_in;
        if (zstd.ascii.eqlIgnoreCase(name, "cubic-out")) return .cubic_out;
        if (zstd.ascii.eqlIgnoreCase(name, "ease")) return .ease;
        if (zstd.ascii.eqlIgnoreCase(name, "ease-in-out") or zstd.ascii.eqlIgnoreCase(name, "cubic-in-out"))
            return .cubic_in_out;
        return .linear;
    }
};

/// Apply the outgoing keyframe's easing to a 0..1 lerp parameter.
pub fn applyEase(ease: Ease, t: f32) f32 {
    const x = zstd.math.clamp(t, 0, 1);
    return switch (ease) {
        .linear => x,
        .ease => x * x * (3 - 2 * x),
        .ease_in => x * x,
        .ease_out => 1 - (1 - x) * (1 - x),
        .cubic_in => x * x * x,
        .cubic_out => 1 - zstd.math.pow(f32, 1 - x, 3),
        .cubic_in_out => if (x < 0.5)
            4 * x * x * x
        else
            1 - zstd.math.pow(f32, -2 * x + 2, 3) / 2,
    };
}

pub const Channel = enum {
    translate,
    scale,
    rotate,
    opacity,

    pub fn json(self: Channel) []const u8 {
        return @tagName(self);
    }

    pub fn parse(name: []const u8) ?Channel {
        if (zstd.mem.eql(u8, name, "translate")) return .translate;
        if (zstd.mem.eql(u8, name, "scale")) return .scale;
        if (zstd.mem.eql(u8, name, "rotate")) return .rotate;
        if (zstd.mem.eql(u8, name, "opacity")) return .opacity;
        return null;
    }
};

pub const Keyframe = struct {
    t_ms: i64,
    x: f32 = 0,
    y: f32 = 0,
    ease: Ease = .linear,
};

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Hold-first / hold-last sampling of a sorted keyframe list.
pub fn samplePair(keys: []const Keyframe, t_ms: i64) struct { x: f32, y: f32 } {
    if (keys.len == 0) return .{ .x = 0, .y = 0 };
    if (t_ms <= keys[0].t_ms) return .{ .x = keys[0].x, .y = keys[0].y };
    if (t_ms >= keys[keys.len - 1].t_ms) {
        const last = keys[keys.len - 1];
        return .{ .x = last.x, .y = last.y };
    }
    var i: usize = 0;
    while (i + 1 < keys.len) : (i += 1) {
        const a = keys[i];
        const b = keys[i + 1];
        if (t_ms > b.t_ms) continue;
        const span: f32 = @floatFromInt(b.t_ms - a.t_ms);
        const u: f32 = if (span <= 0) 1 else @as(f32, @floatFromInt(t_ms - a.t_ms)) / span;
        const e = applyEase(a.ease, u);
        return .{ .x = lerp(a.x, b.x, e), .y = lerp(a.y, b.y, e) };
    }
    const last = keys[keys.len - 1];
    return .{ .x = last.x, .y = last.y };
}

pub const Track = struct {
    target: []const u8,
    channel: Channel,
    keyframes: []const Keyframe,
};

pub fn sampleTransform(tracks: []const Track, target: []const u8, t_ms: i64) shape.Transform {
    var xf = shape.Transform.identity;
    for (tracks) |track| {
        if (!zstd.mem.eql(u8, track.target, target)) continue;
        const p = samplePair(track.keyframes, t_ms);
        switch (track.channel) {
            .translate => {
                xf.tx = p.x;
                xf.ty = p.y;
            },
            .scale => {
                xf.sx = p.x;
                xf.sy = if (track.keyframes.len > 0 and p.y == 0 and p.x != 0) p.x else p.y;
                if (p.y == 0) xf.sy = p.x;
            },
            .rotate => xf.rotate_deg = p.x,
            .opacity => xf.opacity = p.x,
        }
    }
    return xf;
}

const testing = zstd.testing;

test "samplePair holds and lerps at midpoint" {
    const keys = [_]Keyframe{
        .{ .t_ms = 0, .x = 0, .y = 40, .ease = .linear },
        .{ .t_ms = 800, .x = 0, .y = 0, .ease = .linear },
    };
    const mid = samplePair(&keys, 400);
    try testing.expect(mid.y > 19 and mid.y < 21);
    const start = samplePair(&keys, -10);
    try testing.expectEqual(@as(f32, 40), start.y);
    const end = samplePair(&keys, 900);
    try testing.expectEqual(@as(f32, 0), end.y);
}

test "sampleTransform composes translate and opacity" {
    const t_keys = [_]Keyframe{
        .{ .t_ms = 0, .x = 0, .y = 40 },
        .{ .t_ms = 800, .x = 0, .y = 0 },
    };
    const o_keys = [_]Keyframe{
        .{ .t_ms = 0, .x = 0, .y = 0 },
        .{ .t_ms = 800, .x = 1, .y = 0 },
    };
    const tracks = [_]Track{
        .{ .target = "title", .channel = .translate, .keyframes = &t_keys },
        .{ .target = "title", .channel = .opacity, .keyframes = &o_keys },
    };
    const xf = sampleTransform(&tracks, "title", 400);
    try testing.expect(xf.ty > 19 and xf.ty < 21);
    try testing.expect(xf.opacity > 0.49 and xf.opacity < 0.51);
}
