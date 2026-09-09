//! Benchmark: gist recursive env parser vs FieldPlan flat-pass rewrite.
//!
//! Measures parse+deinit over several config shapes with a shared EnvMap.
//! Also reports heap allocation counts via a thin counting allocator.

const std = @import("std");
const gist = @import("gist_env.zig");
const fieldplan = @import("fieldplan_env.zig");

const Impl = enum { gist, fieldplan };

const CountingAllocator = struct {
    parent: std.mem.Allocator,
    alloc_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.bytes_allocated += len;
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
        self.free_count += 1;
    }

    fn reset(self: *CountingAllocator) void {
        self.alloc_count = 0;
        self.free_count = 0;
        self.bytes_allocated = 0;
    }
};

const FlatConfig = struct {
    host: []const u8,
    port: i32,
    debug: bool,
    workers: u32,
    timeout_ms: i64,
};

const NestedDb = struct {
    url: []const u8,
    timeout: i32 = 30,
    pool_size: u32 = 10,
};

const NestedHttp = struct {
    host: []const u8 = "0.0.0.0",
    port: i32 = 8080,
    tls: bool = false,
};

const NestedConfig = struct {
    name: []const u8,
    db: *NestedDb,
    http: *NestedHttp,
    optional_note: ?[]const u8 = null,
};

const DeepLeaf = struct {
    value: []const u8,
    count: i32,
};

const DeepMid = struct {
    label: []const u8,
    leaf: *DeepLeaf,
};

const DeepRoot = struct {
    app: []const u8,
    mid_a: *DeepMid,
    mid_b: *DeepMid,
};

const WideConfig = struct {
    f00: []const u8,
    f01: []const u8,
    f02: []const u8,
    f03: []const u8,
    f04: []const u8,
    f05: i32,
    f06: i32,
    f07: i32,
    f08: i32,
    f09: i32,
    f10: bool,
    f11: bool,
    f12: bool,
    f13: bool,
    f14: bool,
    f15: f64,
    f16: f64,
    f17: f64,
    f18: u64,
    f19: u64,
};

const BenchResult = struct {
    name: []const u8,
    impl: []const u8,
    iterations: usize,
    total_ns: u64,
    ns_per_op: u64,
    allocs_per_op: f64,
    bytes_per_op: f64,
};

fn putPairs(env: *std.process.EnvMap, pairs: []const struct { []const u8, []const u8 }) !void {
    for (pairs) |pair| {
        try env.put(pair[0], pair[1]);
    }
}

fn parseAndFree(comptime impl: Impl, comptime T: type, allocator: std.mem.Allocator, prefix: ?[]const u8, env: std.process.EnvMap) !void {
    switch (impl) {
        .gist => {
            const cfg = try gist.parse(T, allocator, prefix, env);
            gist.deinit(T, allocator, cfg);
        },
        .fieldplan => {
            const cfg = try fieldplan.parse(T, allocator, prefix, env);
            fieldplan.deinit(T, allocator, cfg);
        },
    }
}

fn benchOne(
    comptime impl: Impl,
    comptime T: type,
    parent_allocator: std.mem.Allocator,
    env: std.process.EnvMap,
    prefix: ?[]const u8,
    iterations: usize,
    warmup: usize,
) !BenchResult {
    var counter = CountingAllocator{ .parent = parent_allocator };
    const allocator = counter.allocator();

    var i: usize = 0;
    while (i < warmup) : (i += 1) {
        try parseAndFree(impl, T, allocator, prefix, env);
    }
    counter.reset();

    var timer = try std.time.Timer.start();
    i = 0;
    while (i < iterations) : (i += 1) {
        try parseAndFree(impl, T, allocator, prefix, env);
    }
    const total_ns = timer.read();

    return .{
        .name = @typeName(T),
        .impl = @tagName(impl),
        .iterations = iterations,
        .total_ns = total_ns,
        .ns_per_op = total_ns / iterations,
        .allocs_per_op = @as(f64, @floatFromInt(counter.alloc_count)) / @as(f64, @floatFromInt(iterations)),
        .bytes_per_op = @as(f64, @floatFromInt(counter.bytes_allocated)) / @as(f64, @floatFromInt(iterations)),
    };
}

fn printResult(r: BenchResult) void {
    std.debug.print(
        "{s:12} | {s:24} | {d:>8} ns/op | {d:>8.1} allocs/op | {d:>10.1} B/op | {d} iters\n",
        .{ r.impl, r.name, r.ns_per_op, r.allocs_per_op, r.bytes_per_op, r.iterations },
    );
}

fn printSpeedup(gist_r: BenchResult, fp_r: BenchResult) void {
    const ratio = @as(f64, @floatFromInt(gist_r.ns_per_op)) / @as(f64, @floatFromInt(fp_r.ns_per_op));
    const alloc_ratio = gist_r.allocs_per_op / fp_r.allocs_per_op;
    std.debug.print(
        "             speedup FieldPlan vs gist: {d:.2}x time, alloc ratio gist/fieldplan={d:.2}\n",
        .{ ratio, alloc_ratio },
    );
}

fn runCase(
    comptime T: type,
    case_name: []const u8,
    parent_allocator: std.mem.Allocator,
    env: std.process.EnvMap,
    prefix: ?[]const u8,
    iterations: usize,
) !void {
    const warmup = @max(iterations / 10, 1);
    var gist_r = try benchOne(.gist, T, parent_allocator, env, prefix, iterations, warmup);
    var fp_r = try benchOne(.fieldplan, T, parent_allocator, env, prefix, iterations, warmup);
    gist_r.name = case_name;
    fp_r.name = case_name;
    printResult(gist_r);
    printResult(fp_r);
    printSpeedup(gist_r, fp_r);
    std.debug.print("\n", .{});
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const iterations: usize = 50_000;

    std.debug.print("Env parse benchmark (Zig {s})\n", .{@import("builtin").zig_version_string});
    std.debug.print("iterations/case = {d}, optimize=ReleaseFast\n\n", .{iterations});
    std.debug.print(
        "{s:12} | {s:24} | {s:>11} | {s:>14} | {s:>12} | iters\n",
        .{ "impl", "config", "ns/op", "allocs/op", "B/op" },
    );
    std.debug.print("{s}\n", .{"-" ** 100});

    {
        var env = std.process.EnvMap.init(gpa);
        defer env.deinit();
        try putPairs(&env, &.{
            .{ "HOST", "localhost" },
            .{ "PORT", "8080" },
            .{ "DEBUG", "true" },
            .{ "WORKERS", "4" },
            .{ "TIMEOUT_MS", "1500" },
        });
        try runCase(FlatConfig, "flat", gpa, env, null, iterations);
    }

    {
        var env = std.process.EnvMap.init(gpa);
        defer env.deinit();
        try putPairs(&env, &.{
            .{ "NAME", "scorpio" },
            .{ "DB_URL", "postgres://localhost/db" },
            .{ "DB_TIMEOUT", "60" },
            .{ "DB_POOL_SIZE", "16" },
            .{ "HTTP_HOST", "127.0.0.1" },
            .{ "HTTP_PORT", "3000" },
            .{ "HTTP_TLS", "false" },
        });
        try runCase(NestedConfig, "nested", gpa, env, null, iterations);
    }

    {
        var env = std.process.EnvMap.init(gpa);
        defer env.deinit();
        try putPairs(&env, &.{
            .{ "APP", "bench" },
            .{ "MID_A_LABEL", "a" },
            .{ "MID_A_LEAF_VALUE", "alpha" },
            .{ "MID_A_LEAF_COUNT", "1" },
            .{ "MID_B_LABEL", "b" },
            .{ "MID_B_LEAF_VALUE", "beta" },
            .{ "MID_B_LEAF_COUNT", "2" },
        });
        try runCase(DeepRoot, "deep-nested", gpa, env, null, iterations);
    }

    {
        var env = std.process.EnvMap.init(gpa);
        defer env.deinit();
        try putPairs(&env, &.{
            .{ "F00", "s0" }, .{ "F01", "s1" }, .{ "F02", "s2" }, .{ "F03", "s3" }, .{ "F04", "s4" },
            .{ "F05", "5" }, .{ "F06", "6" }, .{ "F07", "7" }, .{ "F08", "8" }, .{ "F09", "9" },
            .{ "F10", "true" }, .{ "F11", "false" }, .{ "F12", "1" }, .{ "F13", "0" }, .{ "F14", "true" },
            .{ "F15", "1.5" }, .{ "F16", "2.5" }, .{ "F17", "3.5" },
            .{ "F18", "18" }, .{ "F19", "19" },
        });
        try runCase(WideConfig, "wide-flat", gpa, env, null, iterations);
    }

    {
        var env = std.process.EnvMap.init(gpa);
        defer env.deinit();
        try putPairs(&env, &.{
            .{ "APP_HOST", "localhost" },
            .{ "APP_PORT", "8080" },
            .{ "APP_DEBUG", "true" },
            .{ "APP_WORKERS", "4" },
            .{ "APP_TIMEOUT_MS", "1500" },
        });
        try runCase(FlatConfig, "flat+prefix", gpa, env, "APP", iterations);
    }

    std.debug.print("Done.\n", .{});
}

test "correctness parity: flat" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOST", "localhost");
    try env.put("PORT", "9000");
    try env.put("DEBUG", "false");
    try env.put("WORKERS", "8");
    try env.put("TIMEOUT_MS", "100");

    const g = try gist.parse(FlatConfig, allocator, null, env);
    defer gist.deinit(FlatConfig, allocator, g);
    const f = try fieldplan.parse(FlatConfig, allocator, null, env);
    defer fieldplan.deinit(FlatConfig, allocator, f);

    try std.testing.expectEqualStrings(g.host, f.host);
    try std.testing.expectEqual(g.port, f.port);
    try std.testing.expectEqual(g.debug, f.debug);
    try std.testing.expectEqual(g.workers, f.workers);
    try std.testing.expectEqual(g.timeout_ms, f.timeout_ms);
}

test "correctness parity: nested" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("NAME", "scorpio");
    try env.put("DB_URL", "postgres://localhost/db");
    try env.put("DB_TIMEOUT", "60");
    try env.put("DB_POOL_SIZE", "16");
    try env.put("HTTP_HOST", "127.0.0.1");
    try env.put("HTTP_PORT", "3000");
    try env.put("HTTP_TLS", "true");

    const g = try gist.parse(NestedConfig, allocator, null, env);
    defer gist.deinit(NestedConfig, allocator, g);
    const f = try fieldplan.parse(NestedConfig, allocator, null, env);
    defer fieldplan.deinit(NestedConfig, allocator, f);

    try std.testing.expectEqualStrings(g.name, f.name);
    try std.testing.expectEqualStrings(g.db.url, f.db.url);
    try std.testing.expectEqual(g.db.timeout, f.db.timeout);
    try std.testing.expectEqual(g.db.pool_size, f.db.pool_size);
    try std.testing.expectEqualStrings(g.http.host, f.http.host);
    try std.testing.expectEqual(g.http.port, f.http.port);
    try std.testing.expectEqual(g.http.tls, f.http.tls);
    try std.testing.expect(g.optional_note == null);
    try std.testing.expect(f.optional_note == null);
}
