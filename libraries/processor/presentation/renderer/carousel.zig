const zstd = @import("std");

pub const Kind = enum {
    none,
    fade,
    slide_left,

    pub fn json(self: Kind) []const u8 {
        return switch (self) {
            .none => "none",
            .fade => "fade",
            .slide_left => "slide_left",
        };
    }

    pub fn parse(name: []const u8) Kind {
        if (zstd.ascii.eqlIgnoreCase(name, "fade")) return .fade;
        if (zstd.ascii.eqlIgnoreCase(name, "slide_left") or zstd.ascii.eqlIgnoreCase(name, "slide-left"))
            return .slide_left;
        return .none;
    }
};

pub const Transition = struct {
    kind: Kind = .none,
    duration_ms: i64 = 350,
};

pub const Timing = struct {
    start_ms: i64,
    duration_ms: i64,

    pub fn end(self: Timing) i64 {
        return self.start_ms + self.duration_ms;
    }

    pub fn contains(self: Timing, t_ms: i64) bool {
        return t_ms >= self.start_ms and t_ms < self.end();
    }
};

/// Largest start_ms <= t_ms. Clamps to last slide after the deck ends.
pub fn slideAt(timings: []const Timing, t_ms: i64) usize {
    if (timings.len == 0) return 0;
    var idx: usize = 0;
    for (timings, 0..) |timing, i| {
        if (timing.start_ms <= t_ms) idx = i;
    }
    return idx;
}

pub fn totalDuration(timings: []const Timing) i64 {
    if (timings.len == 0) return 0;
    const last = timings[timings.len - 1];
    return last.end();
}

const testing = zstd.testing;

test "slideAt clamps and picks current" {
    const t = [_]Timing{
        .{ .start_ms = 0, .duration_ms = 4000 },
        .{ .start_ms = 4000, .duration_ms = 6000 },
    };
    try testing.expectEqual(@as(usize, 0), slideAt(&t, 0));
    try testing.expectEqual(@as(usize, 0), slideAt(&t, 3999));
    try testing.expectEqual(@as(usize, 1), slideAt(&t, 4000));
    try testing.expectEqual(@as(usize, 1), slideAt(&t, 20_000));
    try testing.expectEqual(@as(i64, 10_000), totalDuration(&t));
}
