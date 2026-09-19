//! Head-to-head microbench: old `Directory` + HashMap lookups vs compact `Tree`
//! + sorted-manifest binary search. Run with `zig build bench`.

const std = @import("std");
const libraries = @import("libraries");
const fs = libraries.fs;
const baseline = @import("bench_baseline.zig");
const loader = libraries.processor.documents.loader;
const manifest = libraries.processor.documents.manifest;

const Allocator = std.mem.Allocator;
const Directory = baseline.Directory;
const Tree = loader.Tree;
const DocumentEntry = manifest.DocumentEntry;
const ChunkEntry = manifest.ChunkEntry;

const groups: usize = 16;
const subgroups: usize = 8;
const files_per: usize = 16;
const expected_files: usize = groups * subgroups * files_per;

const load_rounds: usize = 8;
const lookup_rounds: usize = 8;
const scan_rounds: usize = 64;
const manifest_docs: usize = 10_000;
const manifest_lookups: usize = 200_000;
const chunk_count: usize = 256;
const chunk_lookups: usize = 200_000;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const root_path = try makeFixture(allocator, io);
    defer allocator.free(root_path);

    try checkSameIndex(allocator, root_path);

    std.debug.print("\n=== document index bench (ReleaseFast) ===\n", .{});
    std.debug.print(
        "fixture: {d} files, {d} groups x {d} subgroups x {d} files\n\n",
        .{ expected_files, groups, subgroups, files_per },
    );

    try benchLoad(allocator, io, root_path);
    try benchLookupAndScan(allocator, io, root_path);
    try benchManifest(allocator, io);
    std.debug.print("\n", .{});
}

fn makeFixture(allocator: Allocator, io: std.Io) ![]u8 {
    const cwd = fs.cwd();
    try cwd.makePath(".zig-cache/tmp");

    const stamp: u64 = @intCast(@max(0, std.Io.Clock.real.now(io).toNanoseconds()));
    const rel = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/document-index-bench-{d}", .{stamp});
    defer allocator.free(rel);
    try cwd.makePath(rel);

    var body_buf: [32]u8 = undefined;
    var g: usize = 0;
    while (g < groups) : (g += 1) {
        var s: usize = 0;
        while (s < subgroups) : (s += 1) {
            var f: usize = 0;
            while (f < files_per) : (f += 1) {
                const sub = try std.fmt.allocPrint(
                    allocator,
                    "{s}/g{d:0>2}/s{d:0>2}/f{d:0>3}.md",
                    .{ rel, g, s, f },
                );
                defer allocator.free(sub);
                const n = std.fmt.printInt(&body_buf, f, 10, .lower, .{});
                try cwd.writeFile(.{ .sub_path = sub, .data = body_buf[0..n] });
            }
        }
    }

    return fs.realpathAlloc(allocator, rel);
}

fn checkSameIndex(allocator: Allocator, root_path: []const u8) !void {
    var dir = try Directory.load(allocator, root_path);
    defer dir.deinit();
    var tree = try Tree.load(allocator, root_path);
    defer tree.deinit();

    if (dir.files.len != expected_files or tree.files.len != expected_files) {
        std.debug.print(
            "index mismatch: old files={d} new files={d} expected={d}\n",
            .{ dir.files.len, tree.files.len, expected_files },
        );
        return error.IndexMismatch;
    }

    for (dir.files) |file| {
        if (tree.get(file.path) == null) {
            std.debug.print("new Tree missed {s}\n", .{file.path});
            return error.IndexMismatch;
        }
    }
}

fn benchLoad(allocator: Allocator, io: std.Io, root_path: []const u8) !void {
    var old_times: [load_rounds]u64 = undefined;
    var new_times: [load_rounds]u64 = undefined;

    var i: usize = 0;
    while (i < load_rounds) : (i += 1) {
        const t0 = std.Io.Clock.awake.now(io);
        var dir = try Directory.load(allocator, root_path);
        std.mem.doNotOptimizeAway(dir.files.len);
        old_times[i] = nsSince(io, t0);
        dir.deinit();
    }

    i = 0;
    while (i < load_rounds) : (i += 1) {
        const t0 = std.Io.Clock.awake.now(io);
        var tree = try Tree.load(allocator, root_path);
        std.mem.doNotOptimizeAway(tree.files.len);
        new_times[i] = nsSince(io, t0);
        tree.deinit();
    }

    const old_ns = median(&old_times);
    const new_ns = median(&new_times);

    const old_bytes = try measureLoadBytes(Directory, Directory.load, Directory.deinit, root_path);
    const new_bytes = try measureLoadBytes(Tree, Tree.load, Tree.deinit, root_path);

    var dir = try Directory.load(allocator, root_path);
    defer dir.deinit();
    var tree = try Tree.load(allocator, root_path);
    defer tree.deinit();

    printRow("load Directory (old)", old_ns, 1);
    printRow("load Tree (new)", new_ns, 1);
    printSpeedup(old_ns, new_ns);
    printPair("requested bytes after load", old_bytes, new_bytes);
    printPair("structural payload", directoryPayload(&dir), treePayload(&tree));
    std.debug.print("\n", .{});
}

fn measureLoadBytes(
    comptime T: type,
    comptime loadFn: fn (Allocator, []const u8) anyerror!T,
    comptime deinitFn: fn (*T) void,
    root_path: []const u8,
) !usize {
    var gpa: std.heap.DebugAllocator(.{
        .enable_memory_limit = true,
        .safety = false,
        .thread_safe = false,
        .stack_trace_frames = 0,
    }) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var loaded = try loadFn(allocator, root_path);
    const bytes = gpa.total_requested_bytes;
    deinitFn(&loaded);
    return bytes;
}

fn directoryPayload(dir: *const Directory) usize {
    var n: usize = dir.root_path.len;
    n += dir.folders.len * @sizeOf(baseline.Folder);
    n += dir.files.len * @sizeOf(baseline.File);
    for (dir.folders) |folder| {
        n += folder.path.len;
        n += folder.file_indices.len * @sizeOf(usize);
        n += folder.child_indices.len * @sizeOf(usize);
    }
    for (dir.files) |file| {
        n += file.path.len;
    }
    n += dir.file_by_path.capacity() * (@sizeOf(usize) + @sizeOf(u64));
    n += dir.folder_by_path.capacity() * (@sizeOf(usize) + @sizeOf(u64));
    return n;
}

fn treePayload(tree: *const Tree) usize {
    return tree.root_path.len +
        tree.names.len +
        tree.nodes.len * @sizeOf(loader.Node) +
        tree.files.len * @sizeOf(u32);
}

fn benchLookupAndScan(allocator: Allocator, io: std.Io, root_path: []const u8) !void {
    var dir = try Directory.load(allocator, root_path);
    defer dir.deinit();
    var tree = try Tree.load(allocator, root_path);
    defer tree.deinit();

    var old_lookup: [lookup_rounds]u64 = undefined;
    var new_lookup: [lookup_rounds]u64 = undefined;
    var r: usize = 0;
    while (r < lookup_rounds) : (r += 1) {
        const t0 = std.Io.Clock.awake.now(io);
        var hits: usize = 0;
        for (dir.files) |file| {
            if (dir.getFile(file.path) != null) hits += 1;
        }
        std.mem.doNotOptimizeAway(hits);
        old_lookup[r] = nsSince(io, t0);
    }
    r = 0;
    while (r < lookup_rounds) : (r += 1) {
        const t0 = std.Io.Clock.awake.now(io);
        var hits: usize = 0;
        for (dir.files) |file| {
            if (tree.get(file.path) != null) hits += 1;
        }
        std.mem.doNotOptimizeAway(hits);
        new_lookup[r] = nsSince(io, t0);
    }

    const old_lookup_ns = median(&old_lookup);
    const new_lookup_ns = median(&new_lookup);
    printRow("lookup all files (old HashMap)", old_lookup_ns, expected_files);
    printRow("lookup all files (new binary search)", new_lookup_ns, expected_files);
    printSpeedup(old_lookup_ns, new_lookup_ns);
    std.debug.print("\n", .{});

    var old_scan: [scan_rounds]u64 = undefined;
    var new_scan: [scan_rounds]u64 = undefined;
    r = 0;
    while (r < scan_rounds) : (r += 1) {
        const t0 = std.Io.Clock.awake.now(io);
        var n: usize = 0;
        for (dir.files) |file| {
            const rel = relativePath(dir.root_path, file.path) orelse continue;
            n += rel.len;
        }
        std.mem.doNotOptimizeAway(n);
        old_scan[r] = nsSince(io, t0);
    }
    r = 0;
    while (r < scan_rounds) : (r += 1) {
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const t0 = std.Io.Clock.awake.now(io);
        var n: usize = 0;
        for (tree.files) |id| {
            const abs = try tree.pathInto(id, &abs_buf);
            const rel = try tree.relativePathInto(id, &rel_buf);
            n += abs.len + rel.len;
        }
        std.mem.doNotOptimizeAway(n);
        new_scan[r] = nsSince(io, t0);
    }

    const old_scan_ns = median(&old_scan);
    const new_scan_ns = median(&new_scan);
    printRow("scan files for pack (old stored paths)", old_scan_ns, expected_files);
    printRow("scan files for pack (new pathInto)", new_scan_ns, expected_files);
    printSpeedup(old_scan_ns, new_scan_ns);
    std.debug.print("\n", .{});
}

fn benchManifest(allocator: Allocator, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = try a.alloc(DocumentEntry, manifest_docs);
    const slugs = try a.alloc([]u8, manifest_docs);
    var i: usize = 0;
    while (i < manifest_docs) : (i += 1) {
        slugs[i] = try std.fmt.allocPrint(a, "post-{d:0>5}", .{i});
        docs[i] = .{
            .slug = slugs[i],
            .path = slugs[i],
            .chunk = @intCast(i % chunk_count),
            .offset = 0,
            .length = 1,
            .modified_at = 1,
            .sha256 = "00",
        };
    }

    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(manifest_docs));
    i = 0;
    while (i < manifest_docs) : (i += 1) {
        try map.put(docs[i].slug, i);
    }

    const sorted = try a.dupe(DocumentEntry, docs);
    std.mem.sort(DocumentEntry, sorted, {}, struct {
        fn lessThan(_: void, x: DocumentEntry, y: DocumentEntry) bool {
            return std.mem.lessThan(u8, x.slug, y.slug);
        }
    }.lessThan);

    var fake = manifest.Manifest{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .data = .{ .documents = sorted, .chunks = &.{} },
    };
    defer fake.arena.deinit();

    const t_old = std.Io.Clock.awake.now(io);
    var hits: usize = 0;
    i = 0;
    while (i < manifest_lookups) : (i += 1) {
        const slug = slugs[i % manifest_docs];
        if (map.get(slug) != null) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const old_map_ns = nsSince(io, t_old);

    const t_lin = std.Io.Clock.awake.now(io);
    hits = 0;
    i = 0;
    while (i < manifest_lookups / 20) : (i += 1) {
        const slug = slugs[(i * 17) % manifest_docs];
        if (baseline.linearSlugIndex(docs, slug) != null) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const old_linear_ns = nsSince(io, t_lin) * 20;

    const t_new = std.Io.Clock.awake.now(io);
    hits = 0;
    i = 0;
    while (i < manifest_lookups) : (i += 1) {
        const slug = slugs[i % manifest_docs];
        if (fake.get(slug) != null) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const new_ns = nsSince(io, t_new);

    std.debug.print("manifest get  {d} docs, {d} lookups\n", .{ manifest_docs, manifest_lookups });
    printRow("  HashMap (old)", old_map_ns, manifest_lookups);
    printRow("  linear scan (old neighborSlugs/cdn)", old_linear_ns, manifest_lookups);
    printRow("  binary search (new)", new_ns, manifest_lookups);
    printSpeedup(old_map_ns, new_ns);
    {
        var buf: [32]u8 = undefined;
        std.debug.print("  vs linear scan: {s}\n\n", .{fmtRatioInto(&buf, old_linear_ns, new_ns)});
    }

    const chunks_unsorted = try a.alloc(ChunkEntry, chunk_count);
    const chunks_sorted = try a.alloc(ChunkEntry, chunk_count);
    i = 0;
    while (i < chunk_count) : (i += 1) {
        chunks_unsorted[i] = .{
            .id = @intCast(i),
            .file = "chunk.dat",
            .size = 1,
            .sha256 = "00",
        };
        chunks_sorted[i] = chunks_unsorted[i];
    }
    i = 0;
    while (i < chunk_count) : (i += 1) {
        const j = (i * 7) % chunk_count;
        const tmp = chunks_unsorted[i];
        chunks_unsorted[i] = chunks_unsorted[j];
        chunks_unsorted[j] = tmp;
    }

    const t_chunk_old = std.Io.Clock.awake.now(io);
    hits = 0;
    i = 0;
    while (i < chunk_lookups) : (i += 1) {
        const id: u32 = @intCast(i % chunk_count);
        if (baseline.linearChunkById(chunks_unsorted, id) != null) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const old_chunk_ns = nsSince(io, t_chunk_old);

    const t_chunk_new = std.Io.Clock.awake.now(io);
    hits = 0;
    i = 0;
    while (i < chunk_lookups) : (i += 1) {
        const id: u32 = @intCast(i % chunk_count);
        if (manifest.findChunk(chunks_sorted, id) != null) hits += 1;
    }
    std.mem.doNotOptimizeAway(hits);
    const new_chunk_ns = nsSince(io, t_chunk_new);

    std.debug.print("chunkById  {d} chunks, {d} lookups\n", .{ chunk_count, chunk_lookups });
    printRow("  linear scan (old cache/cdn)", old_chunk_ns, chunk_lookups);
    printRow("  binary search (new)", new_chunk_ns, chunk_lookups);
    printSpeedup(old_chunk_ns, new_chunk_ns);
}

fn relativePath(root: []const u8, abs_path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, abs_path, root)) return null;
    if (abs_path.len <= root.len + 1) return null;
    return abs_path[root.len + 1 ..];
}

fn nsSince(io: std.Io, start: std.Io.Timestamp) u64 {
    const end = std.Io.Clock.awake.now(io);
    const ns = start.durationTo(end).toNanoseconds();
    return @intCast(@max(0, ns));
}

fn median(times: []u64) u64 {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return times[times.len / 2];
}

fn printRow(label: []const u8, total_ns: u64, ops: usize) void {
    const ns_op: u64 = if (ops == 0) 0 else total_ns / ops;
    var buf: [32]u8 = undefined;
    std.debug.print("  {s:<42} {s:>10}  {d:>8} ns/op\n", .{ label, fmtTimeInto(&buf, total_ns), ns_op });
}

fn printSpeedup(old_ns: u64, new_ns: u64) void {
    var buf: [32]u8 = undefined;
    std.debug.print("  speedup {s}\n", .{fmtRatioInto(&buf, old_ns, new_ns)});
}

fn printPair(label: []const u8, old_n: usize, new_n: usize) void {
    var old_buf: [32]u8 = undefined;
    var new_buf: [32]u8 = undefined;
    var ratio_buf: [32]u8 = undefined;
    std.debug.print(
        "  {s:<28} old {s}   new {s}   ({s} less)\n",
        .{
            label,
            fmtBytesInto(&old_buf, old_n),
            fmtBytesInto(&new_buf, new_n),
            fmtRatioInto(&ratio_buf, old_n, new_n),
        },
    );
}

fn fmtRatioInto(buf: []u8, old_n: u64, new_n: u64) []const u8 {
    if (new_n == 0) return "inf";
    const ratio = @as(f64, @floatFromInt(old_n)) / @as(f64, @floatFromInt(new_n));
    return std.fmt.bufPrint(buf, "{d:.2}x", .{ratio}) catch "?";
}

fn fmtTimeInto(buf: []u8, ns: u64) []const u8 {
    if (ns >= std.time.ns_per_s) {
        return std.fmt.bufPrint(buf, "{d:.2} s", .{
            @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s),
        }) catch "?";
    }
    if (ns >= std.time.ns_per_ms) {
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{
            @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms),
        }) catch "?";
    }
    if (ns >= std.time.ns_per_us) {
        return std.fmt.bufPrint(buf, "{d:.1} us", .{
            @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_us),
        }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} ns", .{ns}) catch "?";
}

fn fmtBytesInto(buf: []u8, n: usize) []const u8 {
    if (n >= 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.2} MiB", .{
            @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0),
        }) catch "?";
    }
    if (n >= 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{
            @as(f64, @floatFromInt(n)) / 1024.0,
        }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}
