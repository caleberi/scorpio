const zstd = @import("std");
const fs = @import("../../compat_fs.zig");
const loader = @import("loader.zig");
const manifest = @import("manifest.zig");
const common = @import("common");
const unixTimestamp = common.utils.unixTimestamp;

const Directory = loader.Directory;
const File = loader.File;
const Sha256 = zstd.crypto.hash.sha2.Sha256;

const OversizePolicy = enum { own_chunk, split, fail };
const HashAlgorithm = enum { sha256, sha512, blake3, none };
const SlugSource = enum { name, relative_path, absolute_path, none };

/// Upper bound on a single document we are willing to read into memory.
const max_document_bytes: usize = 256 * 1024 * 1024;

pub const Config = struct {
    output_dir: []const u8,
    chunk_basename: []const u8 = "chunk",
    packing_extension: []const u8 = ".dat",
    manifest_name: []const u8 = "manifest.json",

    max_chunk_size: usize = 4 * 1024 * 1024,
    oversize_policy: OversizePolicy = .own_chunk,

    included_extensions: []const []const u8 = &.{ ".md", ".markdown" },
    follow_symlinks: bool = false,
    skip_hidden: bool = true,

    compute_hash: bool = true,
    hash_algorithm: HashAlgorithm = .sha256,

    slug_from: SlugSource = .relative_path,
    alignment: usize = 1,

    /// Trigger a full repack when dead (unreferenced) bytes exceed this
    /// fraction of the total packed bytes across surviving chunks.
    compaction_threshold: f32 = 0.5,
};

/// A document selected for packing, together with the derived slug/path and
/// the decision the diff phase reached about how to (re)pack it.
const Planned = struct {
    slug: []const u8,
    rel_path: []const u8,
    abs_path: []const u8,
    modified_at: i64,
    decision: Decision,

    const Decision = union(enum) {
        /// Reuse the byte range from the previous manifest verbatim.
        reuse: manifest.DocumentEntry,
        /// (Re)write these bytes into a fresh tail chunk.
        write: Payload,
    };

    const Payload = struct {
        content: []u8,
        sha256_hex: []const u8,
    };
};

pub const Packer = struct {
    allocator: zstd.mem.Allocator,
    config: Config,
    arena: zstd.heap.ArenaAllocator,
    directory: *Directory,

    out_dir: ?fs.Dir = null,
    prev: ?manifest.Manifest = null,

    // Active chunk write state.
    current_chunk: u32 = 0,
    current_offset: u64 = 0,
    chunk_file: ?fs.File = null,
    chunk_name: []const u8 = &.{},
    chunk_hasher: Sha256 = undefined,

    // Accumulated manifest entries.
    docs: zstd.ArrayList(manifest.DocumentEntry) = .empty,
    chunks: zstd.ArrayList(manifest.ChunkEntry) = .empty,

    pub fn init(allocator: zstd.mem.Allocator, config: Config, directory: *Directory) Packer {
        return .{
            .allocator = allocator,
            .config = config,
            .arena = zstd.heap.ArenaAllocator.init(allocator),
            .directory = directory,
        };
    }

    pub fn deinit(self: *Packer) void {
        if (self.chunk_file) |file| file.close();
        if (self.out_dir) |*dir| dir.close();
        if (self.prev) |*prev| prev.deinit();
        self.docs.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn pack(self: *Packer) !void {
        try self.openOutputDir();
        self.prev = manifest.Manifest.load(
            self.allocator,
            self.out_dir.?,
            self.config.manifest_name,
        ) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        const planned = try self.selectAndDiff();
        defer self.freePayloads(planned);

        if (self.prev != null and (self.shouldCompact(planned) or self.prevExtensionMismatch())) {
            try self.compact(planned);
        } else {
            try self.emitIncremental(planned);
        }

        try self.writeManifest();
    }

    /// Walk the flat file index (already recursive courtesy of the loader),
    /// filter to documents, derive slugs, and decide reuse vs. rewrite.
    fn selectAndDiff(self: *Packer) ![]Planned {
        const strings = self.arena.allocator();

        var planned: zstd.ArrayList(Planned) = .empty;
        errdefer planned.deinit(self.allocator);

        var seen_slugs = zstd.StringHashMap(void).init(self.allocator);
        defer seen_slugs.deinit();

        for (self.directory.files) |file| {
            const rel_path = self.relativePath(file.path) orelse continue;
            if (!self.matchesExtension(file.path)) continue;
            if (self.config.skip_hidden and isHidden(rel_path)) continue;

            const slug = try self.deriveSlug(strings, file.path, rel_path);
            if (seen_slugs.contains(slug)) return error.DuplicateSlug;
            try seen_slugs.put(slug, {});

            const decision = try self.decide(file, slug);
            try planned.append(self.allocator, .{
                .slug = slug,
                .rel_path = try strings.dupe(u8, rel_path),
                .abs_path = try strings.dupe(u8, file.path),
                .modified_at = @intCast(file.modified_at),
                .decision = decision,
            });
        }

        // Sort by path so the packed layout is deterministic regardless of the
        // filesystem's directory iteration order.
        const Sort = struct {
            fn lessThan(_: void, a: Planned, b: Planned) bool {
                return zstd.mem.order(u8, a.rel_path, b.rel_path) == .lt;
            }
        };
        zstd.mem.sort(Planned, planned.items, {}, Sort.lessThan);

        return planned.toOwnedSlice(self.allocator);
    }

    /// Decide how a single file should be packed relative to the prior manifest.
    fn decide(self: *Packer, file: File, slug: []const u8) !Planned.Decision {
        const prev_entry: ?*const manifest.DocumentEntry = if (self.prev) |*prev| prev.get(slug) else null;

        const mtime: i64 = @intCast(file.modified_at);
        if (prev_entry) |entry| {
            if (entry.modified_at == mtime) {
                return .{ .reuse = entry.* };
            }
        }

        const content = try fs.cwd().readFileAlloc(
            self.allocator,
            file.path,
            max_document_bytes,
        );
        errdefer self.allocator.free(content);
        const hex = try self.hashHex(content);

        if (prev_entry) |entry| {
            if (zstd.mem.eql(u8, hex, entry.sha256)) {
                self.allocator.free(content);
                return .{ .reuse = entry.* };
            }
        }

        return .{ .write = .{
            .content = content,
            .sha256_hex = hex,
        } };
    }

    fn freePayloads(self: *Packer, planned: []Planned) void {
        for (planned) |item| {
            switch (item.decision) {
                .write => |payload| {
                    self.allocator.free(payload.content);
                },
                .reuse => {},
            }
        }
        self.allocator.free(planned);
    }

    /// Force a full rewrite when leftover chunks use a different packing
    /// extension (e.g. `.bin` → `.dat` after a Cloudinary-safe rename).
    fn prevExtensionMismatch(self: *Packer) bool {
        const prev = &(self.prev orelse return false);
        for (prev.data.chunks) |chunk| {
            if (!zstd.mem.endsWith(u8, chunk.file, self.config.packing_extension))
                return true;
        }
        return false;
    }

    /// Estimate the dead-byte ratio across surviving previous chunks. A chunk
    /// survives if at least one reused document still points into it; the bytes
    /// of everything else in that chunk are dead weight until we compact.
    fn shouldCompact(self: *Packer, planned: []const Planned) bool {
        const prev = &self.prev.?;

        var live_by_chunk = zstd.AutoHashMap(u32, u64).init(self.allocator);
        defer live_by_chunk.deinit();

        var new_bytes: u64 = 0;
        for (planned) |item| {
            switch (item.decision) {
                .reuse => |entry| {
                    const gop = live_by_chunk.getOrPut(entry.chunk) catch return false;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += entry.length;
                },
                .write => |payload| new_bytes += payload.content.len,
            }
        }

        var surviving_total: u64 = 0;
        var dead: u64 = 0;
        for (prev.data.chunks) |chunk| {
            const live = live_by_chunk.get(chunk.id) orelse continue;
            surviving_total += chunk.size;
            dead += chunk.size -| live;
        }

        const total = surviving_total + new_bytes;
        if (total == 0) return false;

        const ratio = @as(f32, @floatFromInt(dead)) / @as(f32, @floatFromInt(total));
        return ratio > self.config.compaction_threshold;
    }

    /// Incremental emit: reused documents keep their chunk/offset untouched;
    /// only rewritten documents are appended to brand new tail chunks.
    fn emitIncremental(self: *Packer, planned: []const Planned) !void {
        self.current_chunk = self.nextChunkId();

        for (planned) |item| {
            switch (item.decision) {
                .reuse => |entry| try self.appendReused(item, entry),
                .write => |payload| try self.writeContent(
                    item,
                    payload.content,
                    payload.sha256_hex,
                ),
            }
        }
        try self.finishChunk();

        try self.carrySurvivingChunks(planned);
        self.sortChunks();
    }

    /// Full repack: ignore prior layout entirely, rewrite every live document
    /// into chunk_0000.. and delete all stale chunk files afterwards.
    fn compact(self: *Packer, planned: []const Planned) !void {
        self.current_chunk = 0;

        for (planned) |item| {
            switch (item.decision) {
                .write => |payload| try self.writeContent(
                    item,
                    payload.content,
                    payload.sha256_hex,
                ),
                .reuse => {
                    const content = try fs.cwd().readFileAlloc(
                        self.allocator,
                        item.abs_path,
                        max_document_bytes,
                    );
                    defer self.allocator.free(content);
                    const hex = try self.hashHex(content);
                    try self.writeContent(item, content, hex);
                },
            }
        }
        try self.finishChunk();

        // Delete any previous chunk files the new layout did not reproduce.
        // (Reproduced names were already overwritten in place by createFile.)
        if (self.prev) |*prev| {
            var kept = zstd.StringHashMap(void).init(self.allocator);
            defer kept.deinit();
            for (self.chunks.items) |chunk| try kept.put(chunk.file, {});

            for (prev.data.chunks) |chunk| {
                if (kept.contains(chunk.file)) continue;
                self.out_dir.?.deleteFile(chunk.file) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }
        self.sortChunks();
    }

    /// Copy a reused document's entry into the new manifest unchanged, but
    /// refresh its mtime so the next run can take the fast path.
    fn appendReused(self: *Packer, item: Planned, entry: manifest.DocumentEntry) !void {
        try self.docs.append(self.allocator, .{
            .slug = item.slug,
            .path = item.rel_path,
            .chunk = entry.chunk,
            .offset = entry.offset,
            .length = entry.length,
            .modified_at = item.modified_at,
            .sha256 = entry.sha256,
        });
    }

    /// Carry forward the ChunkEntry for every previous chunk still referenced
    /// by a reused document, and delete the files of chunks that went fully dead.
    fn carrySurvivingChunks(self: *Packer, planned: []const Planned) !void {
        const prev = &(self.prev orelse return);

        var referenced = zstd.AutoHashMap(u32, void).init(self.allocator);
        defer referenced.deinit();
        for (planned) |item| {
            switch (item.decision) {
                .reuse => |entry| try referenced.put(entry.chunk, {}),
                .write => {},
            }
        }

        for (prev.data.chunks) |chunk| {
            if (referenced.contains(chunk.id)) {
                try self.chunks.append(self.allocator, chunk);
            } else {
                self.out_dir.?.deleteFile(chunk.file) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        }
    }

    /// Append one document's bytes into the current tail chunk, rolling to a
    /// new chunk when it would overflow max_chunk_size. Oversized documents get
    /// a dedicated chunk per the configured policy.
    fn writeContent(self: *Packer, item: Planned, content: []const u8, sha256_hex: []const u8) !void {
        if (content.len > self.config.max_chunk_size) {
            switch (self.config.oversize_policy) {
                .fail => return error.DocumentTooLarge,
                .own_chunk, .split => {},
            }
            try self.finishChunk();
            try self.openChunk();
            try self.putBytes(content);
            try self.recordDoc(item, 0, content.len, sha256_hex);
            try self.finishChunk();
            return;
        }

        if (self.chunk_file == null) try self.openChunk();

        const alignment = @max(self.config.alignment, 1);
        var offset = zstd.mem.alignForward(u64, self.current_offset, alignment);
        if (offset + content.len > self.config.max_chunk_size) {
            try self.finishChunk();
            try self.openChunk();
            offset = 0;
        }

        if (offset > self.current_offset) try self.pad(offset - self.current_offset);
        try self.putBytes(content);
        try self.recordDoc(item, offset, content.len, sha256_hex);
    }

    fn recordDoc(self: *Packer, item: Planned, offset: u64, length: u64, sha256_hex: []const u8) !void {
        try self.docs.append(self.allocator, .{
            .slug = item.slug,
            .path = item.rel_path,
            .chunk = self.current_chunk,
            .offset = offset,
            .length = length,
            .modified_at = item.modified_at,
            .sha256 = try self.arena.allocator().dupe(u8, sha256_hex),
        });
    }

    fn openChunk(self: *Packer) !void {
        zstd.debug.assert(self.chunk_file == null);
        const name = try self.chunkName(self.current_chunk);
        self.chunk_file = try self.out_dir.?.createFile(name, .{ .truncate = true });
        self.chunk_name = name;
        self.current_offset = 0;
        self.chunk_hasher = Sha256.init(.{});
    }

    fn finishChunk(self: *Packer) !void {
        const file = self.chunk_file orelse return;
        file.close();
        self.chunk_file = null;

        var digest: [Sha256.digest_length]u8 = undefined;
        self.chunk_hasher.final(&digest);
        const hex = try self.arena.allocator().dupe(u8, &zstd.fmt.bytesToHex(digest, .lower));

        try self.chunks.append(self.allocator, .{
            .id = self.current_chunk,
            .file = self.chunk_name,
            .size = self.current_offset,
            .sha256 = hex,
        });

        self.current_chunk += 1;
        self.current_offset = 0;
    }

    fn putBytes(self: *Packer, bytes: []const u8) !void {
        try self.chunk_file.?.writeAll(bytes);
        self.chunk_hasher.update(bytes);
        self.current_offset += bytes.len;
    }

    fn pad(self: *Packer, count: u64) !void {
        var remaining = count;
        var zeros: [64]u8 = @splat(0);
        while (remaining > 0) {
            const step: usize = @intCast(@min(remaining, zeros.len));
            try self.putBytes(zeros[0..step]);
            remaining -= step;
        }
    }

    fn openOutputDir(self: *Packer) !void {
        try fs.cwd().makePath(self.config.output_dir);
        self.out_dir = try fs.cwd().openDir(self.config.output_dir, .{});
    }

    fn writeManifest(self: *Packer) !void {
        const data = manifest.Data{
            .version = 1,
            .generated_at = unixTimestamp(),
            .chunk_size = self.config.max_chunk_size,
            .chunks = self.chunks.items,
            .documents = self.docs.items,
        };
        try manifest.Manifest.write(
            self.allocator,
            self.out_dir.?,
            self.config.manifest_name,
            data,
        );
    }

    fn nextChunkId(self: *Packer) u32 {
        const prev = &(self.prev orelse return 0);
        var max_id: ?u32 = null;
        for (prev.data.chunks) |chunk| {
            if (max_id == null or chunk.id > max_id.?) max_id = chunk.id;
        }
        return if (max_id) |id| id + 1 else 0;
    }

    fn sortChunks(self: *Packer) void {
        const Sort = struct {
            fn lessThan(_: void, a: manifest.ChunkEntry, b: manifest.ChunkEntry) bool {
                return a.id < b.id;
            }
        };
        zstd.mem.sort(manifest.ChunkEntry, self.chunks.items, {}, Sort.lessThan);
    }

    fn chunkName(self: *Packer, id: u32) ![]const u8 {
        return zstd.fmt.allocPrint(self.arena.allocator(), "{s}_{d:0>4}{s}", .{
            self.config.chunk_basename,
            id,
            self.config.packing_extension,
        });
    }

    fn hashHex(self: *Packer, content: []const u8) ![]const u8 {
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(content, &digest, .{});
        return self.arena.allocator().dupe(u8, &zstd.fmt.bytesToHex(digest, .lower));
    }

    fn relativePath(self: *Packer, abs_path: []const u8) ?[]const u8 {
        const root = self.directory.root_path;
        if (!zstd.mem.startsWith(u8, abs_path, root)) return null;
        if (abs_path.len <= root.len + 1) return null;
        return abs_path[root.len + 1 ..];
    }

    fn matchesExtension(self: *Packer, path: []const u8) bool {
        const ext = fs.path.extension(path);
        for (self.config.included_extensions) |candidate| {
            if (zstd.mem.eql(u8, ext, candidate)) return true;
        }
        return false;
    }

    fn deriveSlug(self: *Packer, strings: zstd.mem.Allocator, abs_path: []const u8, rel_path: []const u8) ![]const u8 {
        return switch (self.config.slug_from) {
            .name => strings.dupe(u8, stripExtension(fs.path.basename(abs_path))),
            .relative_path => strings.dupe(u8, stripExtension(rel_path)),
            .absolute_path => strings.dupe(u8, abs_path),
            .none => strings.dupe(u8, rel_path),
        };
    }
};

fn stripExtension(path: []const u8) []const u8 {
    const ext = fs.path.extension(path);
    return path[0 .. path.len - ext.len];
}

fn isHidden(rel_path: []const u8) bool {
    var it = zstd.mem.splitScalar(u8, rel_path, fs.path.sep);
    while (it.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return true;
    }
    return false;
}

const testing = zstd.testing;

fn tmpJoin(allocator: zstd.mem.Allocator, tmp: *testing.TmpDir, sub: []const u8) ![]u8 {
    return zstd.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub });
}

fn readDoc(
    allocator: zstd.mem.Allocator,
    out_dir: fs.Dir,
    m: *const manifest.Manifest,
    slug: []const u8,
) ![]u8 {
    const doc = m.get(slug).?;
    const chunk = for (m.data.chunks) |chunk| {
        if (chunk.id == doc.chunk) break chunk;
    } else return error.ChunkNotFound;

    const bytes = try out_dir.readFileAlloc(allocator, chunk.file, 64 * 1024 * 1024);
    defer allocator.free(bytes);
    return allocator.dupe(u8, bytes[doc.offset .. doc.offset + doc.length]);
}

test "full pack writes chunks and documents read back byte-identical" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/blog");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/blog/a.md", .data = "# Alpha\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/blog/b.md", .data = "# Bravo\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/blog/ignore.txt", .data = "not a doc" });

    const src_path = try tmpJoin(allocator, &tmp, "src");
    defer allocator.free(src_path);
    const out_full = try tmpJoin(allocator, &tmp, "pack");
    defer allocator.free(out_full);

    var directory = try Directory.load(allocator, src_path);
    defer directory.deinit();

    var packer = Packer.init(allocator, .{ .output_dir = out_full }, &directory);
    defer packer.deinit();
    try packer.pack();

    var out_dir = try fs.cwd().openDir(out_full, .{});
    defer out_dir.close();

    var manifest_file = try manifest.Manifest.load(allocator, out_dir, "manifest.json");
    defer manifest_file.deinit();

    try testing.expectEqual(@as(usize, 2), manifest_file.data.documents.len);
    for (manifest_file.data.chunks) |chunk| try testing.expect(chunk.size <= 4 * 1024 * 1024);

    const a = try readDoc(allocator, out_dir, &manifest_file, "blog/a");
    defer allocator.free(a);
    try testing.expectEqualStrings("# Alpha\n", a);

    const b = try readDoc(allocator, out_dir, &manifest_file, "blog/b");
    defer allocator.free(b);
    try testing.expectEqualStrings("# Bravo\n", b);
}

test "oversize document gets its own chunk" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");

    const big = try allocator.alloc(u8, 20);
    defer allocator.free(big);
    @memset(big, 'X');
    try tmp.dir.writeFile(io, .{ .sub_path = "src/small.md", .data = "tiny" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/big.md", .data = big });

    const src_path = try tmpJoin(allocator, &tmp, "src");
    defer allocator.free(src_path);
    const pack_dir = try tmpJoin(allocator, &tmp, "pack");
    defer allocator.free(pack_dir);

    var directory = try Directory.load(allocator, src_path);
    defer directory.deinit();

    var packer = Packer.init(allocator, .{
        .output_dir = pack_dir,
        .max_chunk_size = 8,
    }, &directory);
    defer packer.deinit();
    try packer.pack();

    var out_dir = try fs.cwd().openDir(pack_dir, .{});
    defer out_dir.close();

    var manifest_file = try manifest.Manifest.load(allocator, out_dir, "manifest.json");
    defer manifest_file.deinit();

    const big_doc = manifest_file.get("big").?;
    const big_chunk = for (manifest_file.data.chunks) |chunk| {
        if (chunk.id == big_doc.chunk) break chunk;
    } else unreachable;
    try testing.expectEqual(@as(u64, 20), big_chunk.size);
    try testing.expectEqual(@as(u64, 20), big_doc.length);
}

test "incremental repack reuses unchanged and rewrites edited" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/keep.md", .data = "stable content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/edit.md", .data = "before" });

    const src_path = try tmpJoin(allocator, &tmp, "src");
    defer allocator.free(src_path);
    const pack_dir = try tmpJoin(allocator, &tmp, "pack");
    defer allocator.free(pack_dir);

    {
        var directory = try Directory.load(allocator, src_path);
        defer directory.deinit();
        var packer = Packer.init(allocator, .{ .output_dir = pack_dir }, &directory);
        defer packer.deinit();
        try packer.pack();
    }

    var out_dir = try fs.cwd().openDir(pack_dir, .{});
    defer out_dir.close();

    const keep_before = blk: {
        var m = try manifest.Manifest.load(allocator, out_dir, "manifest.json");
        defer m.deinit();
        break :blk m.get("keep").?.*;
    };

    try tmp.dir.writeFile(io, .{ .sub_path = "src/edit.md", .data = "after the edit" });

    {
        var directory = try Directory.load(allocator, src_path);
        defer directory.deinit();
        var packer = Packer.init(allocator, .{ .output_dir = pack_dir }, &directory);
        defer packer.deinit();
        try packer.pack();
    }

    var m = try manifest.Manifest.load(allocator, out_dir, "manifest.json");
    defer m.deinit();

    const keep_after = m.get("keep").?;
    try testing.expectEqual(keep_before.chunk, keep_after.chunk);
    try testing.expectEqual(keep_before.offset, keep_after.offset);

    const edit = try readDoc(allocator, out_dir, &m, "edit");
    defer allocator.free(edit);
    try testing.expectEqualStrings("after the edit", edit);
}

test "compaction renumbers chunks and drops dead files" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.md", .data = "aaaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.md", .data = "bbbb" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/c.md", .data = "cccc" });

    const src_path = try tmpJoin(allocator, &tmp, "src");
    defer allocator.free(src_path);
    const pack_dir = try tmpJoin(allocator, &tmp, "pack");
    defer allocator.free(pack_dir);

    // Cap of 8 packs two 4-byte docs per chunk. Sorted layout is deterministic:
    //   chunk_0000 = a + b   (8 bytes)
    //   chunk_0001 = c       (4 bytes)
    const cfg = Config{
        .output_dir = pack_dir,
        .max_chunk_size = 8,
        .compaction_threshold = 0.2,
    };

    {
        var directory = try Directory.load(allocator, src_path);
        defer directory.deinit();
        var packer = Packer.init(allocator, cfg, &directory);
        defer packer.deinit();
        try packer.pack();
    }

    var out_dir = try fs.cwd().openDir(pack_dir, .{});
    defer out_dir.close();

    // Edit a.md: chunk_0000 keeps b live but a's 4 bytes go dead (a partially
    // dead surviving chunk). dead/total = 4/16 = 0.25 > 0.2 -> forces compaction.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.md", .data = "zzzz" });

    {
        var directory = try Directory.load(allocator, src_path);
        defer directory.deinit();
        var packer = Packer.init(allocator, cfg, &directory);
        defer packer.deinit();
        try packer.pack();
    }

    var manifest_file = try manifest.Manifest.load(allocator, out_dir, "manifest.json");
    defer manifest_file.deinit();

    // After compaction chunk ids restart from 0 and are contiguous.
    try testing.expectEqual(@as(usize, 2), manifest_file.data.chunks.len);
    var ids_seen = [_]bool{ false, false };
    for (manifest_file.data.chunks) |chunk| {
        try testing.expect(chunk.id < 2);
        ids_seen[chunk.id] = true;
    }
    try testing.expect(ids_seen[0] and ids_seen[1]);

    // No orphaned chunk files beyond the two live ones (+ manifest.json).
    var count: usize = 0;
    var it = try out_dir.iterate();
    defer it.deinit();
    while (try it.next()) |entry| {
        if (zstd.mem.endsWith(u8, entry.name, ".dat")) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);

    const a = try readDoc(allocator, out_dir, &manifest_file, "a");
    defer allocator.free(a);
    try testing.expectEqualStrings("zzzz", a);
}
