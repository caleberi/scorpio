const zstd = @import("std");

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: f32 = 1,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }

    pub fn toCss(self: Color, buf: []u8) []const u8 {
        if (self.a >= 0.999) {
            return zstd.fmt.bufPrint(
                buf,
                "#{x:0>2}{x:0>2}{x:0>2}",
                .{ self.r, self.g, self.b },
            ) catch "#000000";
        }
        return zstd.fmt.bufPrint(
            buf,
            "rgba({d},{d},{d},{d:.3})",
            .{ self.r, self.g, self.b, self.a },
        ) catch "#000000";
    }
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(hi: u8, lo: u8) ?u8 {
    const h = hexNibble(hi) orelse return null;
    const l = hexNibble(lo) orelse return null;
    return (h << 4) | l;
}

/// Parse `#rgb`, `#rrggbb`, `rgb()`, `rgba()`, or a small set of names.
pub fn parse(text: []const u8) ?Color {
    const t = zstd.mem.trim(u8, text, " \t\n\r");
    if (t.len == 0) return null;

    if (zstd.ascii.eqlIgnoreCase(t, "black")) return Color.rgb(0, 0, 0);
    if (zstd.ascii.eqlIgnoreCase(t, "white")) return Color.rgb(255, 255, 255);
    if (zstd.ascii.eqlIgnoreCase(t, "transparent"))
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    if (t[0] == '#') {
        switch (t.len) {
            4 => {
                const r = hexNibble(t[1]) orelse return null;
                const g = hexNibble(t[2]) orelse return null;
                const b = hexNibble(t[3]) orelse return null;
                return Color.rgb(r * 17, g * 17, b * 17);
            },
            7 => {
                const r = hexByte(t[1], t[2]) orelse return null;
                const g = hexByte(t[3], t[4]) orelse return null;
                const b = hexByte(t[5], t[6]) orelse return null;
                return Color.rgb(r, g, b);
            },
            else => return null,
        }
    }

    const lower_is_rgb = t.len >= 4 and zstd.ascii.eqlIgnoreCase(t[0..3], "rgb");
    if (!lower_is_rgb) return null;

    const open = zstd.mem.indexOfScalar(u8, t, '(') orelse return null;
    const close = zstd.mem.lastIndexOfScalar(u8, t, ')') orelse return null;
    if (close <= open) return null;
    const inner = t[open + 1 .. close];

    var parts: [4]f32 = .{ 0, 0, 0, 1 };
    var count: usize = 0;
    var it = zstd.mem.splitAny(u8, inner, ", ");
    while (it.next()) |raw| {
        const piece = zstd.mem.trim(u8, raw, " \t");
        if (piece.len == 0) continue;
        if (count >= 4) break;
        parts[count] = zstd.fmt.parseFloat(f32, piece) catch return null;
        count += 1;
    }
    if (count < 3) return null;
    return .{
        .r = @intFromFloat(zstd.math.clamp(parts[0], 0, 255)),
        .g = @intFromFloat(zstd.math.clamp(parts[1], 0, 255)),
        .b = @intFromFloat(zstd.math.clamp(parts[2], 0, 255)),
        .a = if (count >= 4) zstd.math.clamp(parts[3], 0, 1) else 1,
    };
}

const testing = zstd.testing;

test "parse hex and named colors" {
    const black = parse("#000").?;
    try testing.expectEqual(@as(u8, 0), black.r);
    const white = parse("#ffffff").?;
    try testing.expectEqual(@as(u8, 255), white.r);
    const red = parse("#f00").?;
    try testing.expectEqual(@as(u8, 255), red.r);
    try testing.expectEqual(@as(u8, 0), red.g);
    try testing.expect(parse("transparent").?.a == 0);
}

test "parse rgba" {
    const c = parse("rgba(10, 20, 30, 0.5)").?;
    try testing.expectEqual(@as(u8, 10), c.r);
    try testing.expectEqual(@as(u8, 20), c.g);
    try testing.expectEqual(@as(u8, 30), c.b);
    try testing.expect(c.a > 0.49 and c.a < 0.51);
}
