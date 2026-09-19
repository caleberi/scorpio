const zstd = @import("std");
const common = @import("common");
const fs = @import("../../compat_fs.zig");

/// One packed chunk file on disk. Chunks are immutable once written.
/// Not `extern`: Zig slices have no C ABI. Field order still packs to 48 bytes.
pub const ChunkEntry = struct {
    size: u64,
    file: []const u8,
    sha256: []const u8,
    id: u32,
    _pad: u32 = 0,
};

/// A single packed document, addressable by a single seek-read into `chunk`
/// at `offset` for `length` bytes.
pub const DocumentEntry = struct {
    offset: u64,
    modified_at: i64,
    slug: []const u8,
    path: []const u8,
    sha256: []const u8,
    length: u32,
    chunk: u32,
};

comptime {
    zstd.debug.assert(@sizeOf(DocumentEntry) == 72);
    zstd.debug.assert(@alignOf(DocumentEntry) == 8);
    zstd.debug.assert(@sizeOf(ChunkEntry) == 48);
    zstd.debug.assert(@alignOf(ChunkEntry) == 8);
}

pub const Data = struct {
    version: u32 = 1,
    generated_at: i64 = 0,
    chunk_size: u64 = 0,
    chunks: []const ChunkEntry = &.{},
    documents: []const DocumentEntry = &.{},
};

const max_manifest_bytes: usize = 64 * 1024 * 1024;

/// A loaded manifest: owns the JSON bytes and record arrays (via `arena`)
/// and provides O(log N) slug -> document lookup.
pub const Manifest = struct {
    arena: zstd.heap.ArenaAllocator,
    data: Data,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn getIndex(self: *const Manifest, slug: []const u8) ?usize {
        const Ctx = struct {
            key: []const u8,
            fn order(ctx: @This(), doc: DocumentEntry) zstd.math.Order {
                return zstd.mem.order(u8, ctx.key, doc.slug);
            }
        };
        return zstd.sort.binarySearch(
            DocumentEntry,
            self.data.documents,
            Ctx{ .key = slug },
            Ctx.order,
        );
    }

    pub fn get(self: *const Manifest, slug: []const u8) ?*const DocumentEntry {
        const index = self.getIndex(slug) orelse return null;
        return &self.data.documents[index];
    }

    pub fn chunkById(self: *const Manifest, id: u32) ?*const ChunkEntry {
        return findChunk(self.data.chunks, id);
    }

    /// Read and parse `manifest_name` from `dir`. Returns error.FileNotFound
    /// when there is no prior manifest so callers can fall back to a full pack.
    pub fn load(allocator: zstd.mem.Allocator, dir: fs.Dir, manifest_name: []const u8) !Manifest {
        var arena = zstd.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const bytes = try dir.readFileAlloc(a, manifest_name, max_manifest_bytes);

        const parsed = try common.json.deserializeLeakyOpts(Data, a, bytes, .{
            .allocate = .alloc_if_needed,
            .ignore_unknown_fields = true,
        });

        const documents = try a.dupe(DocumentEntry, parsed.documents);
        zstd.mem.sort(DocumentEntry, documents, {}, documentSlugLessThan);

        const chunks = try a.dupe(ChunkEntry, parsed.chunks);
        zstd.mem.sort(ChunkEntry, chunks, {}, chunkIdLessThan);

        return .{
            .arena = arena,
            .data = .{
                .version = parsed.version,
                .generated_at = parsed.generated_at,
                .chunk_size = parsed.chunk_size,
                .chunks = chunks,
                .documents = documents,
            },
        };
    }

    /// Serialize `data` to `manifest_name` inside `dir` as minified JSON.
    pub fn write(allocator: zstd.mem.Allocator, dir: fs.Dir, manifest_name: []const u8, data: Data) !void {
        const bytes = try common.json.serializeOpts(
            allocator,
            data,
            .{
                .whitespace = .minified,
            },
        );
        defer allocator.free(bytes);

        var file = try dir.createFile(
            manifest_name,
            .{
                .truncate = true,
            },
        );
        defer file.close();
        try file.writeAll(bytes);
    }
};

pub fn findChunk(chunks: []const ChunkEntry, id: u32) ?*const ChunkEntry {
    const Ctx = struct {
        fn order(key: u32, chunk: ChunkEntry) zstd.math.Order {
            return zstd.math.order(key, chunk.id);
        }
    };
    const index = zstd.sort.binarySearch(ChunkEntry, chunks, id, Ctx.order) orelse return null;
    return &chunks[index];
}

fn documentSlugLessThan(_: void, a: DocumentEntry, b: DocumentEntry) bool {
    return zstd.mem.lessThan(u8, a.slug, b.slug);
}

fn chunkIdLessThan(_: void, a: ChunkEntry, b: ChunkEntry) bool {
    return a.id < b.id;
}

test "manifest round-trips through disk" {
    const allocator = zstd.testing.allocator;

    var tmp = zstd.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.fromIoDir(tmp.dir);

    const chunks = [_]ChunkEntry{
        .{ .id = 0, .file = "chunk_0000.bin", .size = 42, .sha256 = "deadbeef" },
    };
    const documents = [_]DocumentEntry{
        .{
            .slug = "hello-world",
            .path = "blog/hello-world.md",
            .chunk = 0,
            .offset = 0,
            .length = 42,
            .modified_at = 1_733_500_000_000_000_000,
            .sha256 = "cafebabe",
        },
    };

    try Manifest.write(allocator, dir, "manifest.json", .{
        .version = 1,
        .generated_at = 1_733_600_000,
        .chunk_size = 4 * 1024 * 1024,
        .chunks = &chunks,
        .documents = &documents,
    });

    var manifest = try Manifest.load(allocator, dir, "manifest.json");
    defer manifest.deinit();

    try zstd.testing.expectEqual(@as(u32, 1), manifest.data.version);
    try zstd.testing.expectEqual(@as(u64, 4 * 1024 * 1024), manifest.data.chunk_size);
    try zstd.testing.expectEqual(@as(usize, 1), manifest.data.documents.len);

    const doc = manifest.get("hello-world").?;
    try zstd.testing.expectEqualStrings("blog/hello-world.md", doc.path);
    try zstd.testing.expectEqual(@as(u32, 42), doc.length);
    try zstd.testing.expectEqual(@as(i64, 1_733_500_000_000_000_000), doc.modified_at);
    try zstd.testing.expectEqualStrings("cafebabe", doc.sha256);

    try zstd.testing.expect(manifest.get("missing") == null);
    try zstd.testing.expect(manifest.chunkById(0) != null);
    try zstd.testing.expect(manifest.chunkById(9) == null);
}

test "manifest load sorts documents by slug" {
    const allocator = zstd.testing.allocator;

    var tmp = zstd.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = fs.fromIoDir(tmp.dir);

    const chunks = [_]ChunkEntry{
        .{ .id = 2, .file = "chunk_0002.dat", .size = 8, .sha256 = "aa" },
        .{ .id = 0, .file = "chunk_0000.dat", .size = 8, .sha256 = "bb" },
    };
    const documents = [_]DocumentEntry{
        .{
            .slug = "zeta",
            .path = "z.md",
            .chunk = 2,
            .offset = 0,
            .length = 1,
            .modified_at = 1,
            .sha256 = "11",
        },
        .{
            .slug = "alpha",
            .path = "a.md",
            .chunk = 0,
            .offset = 0,
            .length = 1,
            .modified_at = 1,
            .sha256 = "22",
        },
    };

    try Manifest.write(allocator, dir, "manifest.json", .{
        .chunks = &chunks,
        .documents = &documents,
    });

    var manifest = try Manifest.load(allocator, dir, "manifest.json");
    defer manifest.deinit();

    try zstd.testing.expectEqualStrings("alpha", manifest.data.documents[0].slug);
    try zstd.testing.expectEqualStrings("zeta", manifest.data.documents[1].slug);
    try zstd.testing.expectEqual(@as(u32, 0), manifest.data.chunks[0].id);
    try zstd.testing.expectEqual(@as(u32, 2), manifest.data.chunks[1].id);
    try zstd.testing.expectEqualStrings("a.md", manifest.get("alpha").?.path);
    try zstd.testing.expectEqualStrings("z.md", manifest.get("zeta").?.path);
    try zstd.testing.expectEqualStrings("chunk_0002.dat", manifest.chunkById(2).?.file);
}
