const std = @import("std");
const libraries = @import("libraries");
const Cdn = @import("cdn.zig").Cdn;
const DocumentEntry = libraries.processor.documents.manifest.DocumentEntry;
const Manifest = libraries.processor.documents.manifest.Manifest;
const Cloudinary = libraries.uploader.cloudinary.Cloudinary;

pub const BlogCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    chunks: std.StringHashMapUnmanaged([]u8) = .{},
    docs: std.StringHashMapUnmanaged([]u8) = .{},
    cdn: Cdn,
    manifest: *const Manifest,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cloud: *Cloudinary,
        pack_prefix: []const u8,
        pack_dir: []const u8,
        manifest: *const Manifest,
    ) BlogCache {
        return .{
            .allocator = allocator,
            .io = io,
            .cdn = .{
                .allocator = allocator,
                .cloud = cloud,
                .pack_prefix = pack_prefix,
                .pack_dir = pack_dir,
                .client = &cloud.client,
            },
            .manifest = manifest,
        };
    }

    pub fn deinit(self: *BlogCache) void {
        var cit = self.chunks.iterator();
        while (cit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.chunks.deinit(self.allocator);

        var dit = self.docs.iterator();
        while (dit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.docs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn getDocument(self: *BlogCache, slug: []const u8) ![]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.docs.get(slug)) |cached| return cached;

        const doc = self.manifest.get(slug) orelse return error.NotFound;
        const body = try self.loadDocumentUnlocked(doc);
        const key = try self.allocator.dupe(u8, slug);
        errdefer self.allocator.free(key);
        try self.docs.put(self.allocator, key, body);
        return body;
    }

    pub fn prefetch(self: *BlogCache, slugs: []const []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (slugs) |slug| {
            if (self.docs.contains(slug)) continue;
            const doc = self.manifest.get(slug) orelse continue;
            const body = self.loadDocumentUnlocked(doc) catch continue;
            const key = self.allocator.dupe(u8, slug) catch {
                self.allocator.free(body);
                continue;
            };
            self.docs.put(self.allocator, key, body) catch {
                self.allocator.free(key);
                self.allocator.free(body);
            };
        }
    }

    fn loadDocumentUnlocked(self: *BlogCache, doc: *const DocumentEntry) ![]u8 {
        const chunk = for (self.manifest.data.chunks) |c| {
            if (c.id == doc.chunk) break c;
        } else return error.ChunkNotFound;

        const bytes = try self.getChunkUnlocked(chunk.file);
        if (doc.offset + doc.length > bytes.len) return error.InvalidOffset;
        return try self.allocator.dupe(u8, bytes[doc.offset..][0..doc.length]);
    }

    fn getChunkUnlocked(self: *BlogCache, file: []const u8) ![]const u8 {
        if (self.chunks.get(file)) |cached| return cached;
        const bytes = try self.cdn.fetchChunk(file);
        const key = try self.allocator.dupe(u8, file);
        errdefer self.allocator.free(key);
        try self.chunks.put(self.allocator, key, bytes);
        return bytes;
    }
};
