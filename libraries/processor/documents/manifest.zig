const zstd = @import("std");
const fs = @import("../../compat_fs.zig");

/// One packed chunk file on disk. Chunks are immutable once written.
pub const ChunkEntry = struct {
    id: u32,
    file: []const u8,
    size: u64,
    sha256: []const u8,
};

/// A single packed document, addressable by a single seek-read into `chunk`
/// at `offset` for `length` bytes.
pub const DocumentEntry = struct {
    slug: []const u8,
    path: []const u8,
    chunk: u32,
    offset: u64,
    length: u64,

    modified_at: i64,
    sha256: []const u8,
};

pub const Data = struct {
    version: u32 = 1,
    generated_at: i64 = 0,
    chunk_size: u64 = 0,
    chunks: []const ChunkEntry = &.{},
    documents: []const DocumentEntry = &.{},
};

const max_manifest_bytes: usize = 64 * 1024 * 1024;

/// A loaded manifest: owns its backing memory (via `arena`) and provides an
/// O(1) slug -> document lookup for the serve path and incremental diffing.
pub const Manifest = struct {
    arena: zstd.heap.ArenaAllocator,
    data: Data,
    doc_by_slug: zstd.StringHashMap(usize),

    pub fn deinit(self: *Manifest) void {
        self.doc_by_slug.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Manifest, slug: []const u8) ?*const DocumentEntry {
        const index = self.doc_by_slug.get(slug) orelse return null;
        return &self.data.documents[index];
    }

    /// Read and parse `manifest_name` from `dir`. Returns error.FileNotFound
    /// when there is no prior manifest so callers can fall back to a full pack.
    pub fn load(allocator: zstd.mem.Allocator, dir: fs.Dir, manifest_name: []const u8) !Manifest {
        const bytes = try dir.readFileAlloc(allocator, manifest_name, max_manifest_bytes);
        defer allocator.free(bytes);

        var arena = zstd.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const data = try zstd.json.parseFromSliceLeaky(
            Data,
            arena.allocator(),
            bytes,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        );

        var doc_by_slug = zstd.StringHashMap(usize).init(allocator);
        errdefer doc_by_slug.deinit();

        for (data.documents, 0..) |doc, index| {
            try doc_by_slug.put(doc.slug, index);
        }

        return .{
            .arena = arena,
            .data = data,
            .doc_by_slug = doc_by_slug,
        };
    }

    /// Serialize `data` to `manifest_name` inside `dir` as pretty JSON.
    pub fn write(
        allocator: zstd.mem.Allocator,
        dir: fs.Dir,
        manifest_name: []const u8,
        data: Data,
    ) !void {
        const bytes = try zstd.json.Stringify.valueAlloc(
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

test "manifest round-trips through disk" {
    const allocator = zstd.testing.allocator;

    var tmp = zstd.testing.tmpDir(.{});
    defer tmp.cleanup();

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

    try Manifest.write(allocator, tmp.dir, "manifest.json", .{
        .version = 1,
        .generated_at = 1_733_600_000,
        .chunk_size = 4 * 1024 * 1024,
        .chunks = &chunks,
        .documents = &documents,
    });

    var manifest = try Manifest.load(allocator, tmp.dir, "manifest.json");
    defer manifest.deinit();

    try zstd.testing.expectEqual(@as(u32, 1), manifest.data.version);
    try zstd.testing.expectEqual(@as(u64, 4 * 1024 * 1024), manifest.data.chunk_size);
    try zstd.testing.expectEqual(@as(usize, 1), manifest.data.documents.len);

    const doc = manifest.get("hello-world").?;
    try zstd.testing.expectEqualStrings("blog/hello-world.md", doc.path);
    try zstd.testing.expectEqual(@as(u64, 42), doc.length);
    try zstd.testing.expectEqual(@as(i64, 1_733_500_000_000_000_000), doc.modified_at);
    try zstd.testing.expectEqualStrings("cafebabe", doc.sha256);

    try zstd.testing.expect(manifest.get("missing") == null);
}
