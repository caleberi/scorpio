const std = @import("std");
const libraries = @import("libraries");
const Cdn = @import("cdn.zig").Cdn;
const DocumentEntry = libraries.processor.documents.manifest.DocumentEntry;
const Manifest = libraries.processor.documents.manifest.Manifest;
const Cloudinary = libraries.uploader.cloudinary.Cloudinary;

pub const BlogCache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cdn: Cdn,
    manifest: *const Manifest,
    lock: std.Io.RwLock = .init,
    chunks: std.StringHashMapUnmanaged([]u8) = .{},
    docs: std.StringHashMapUnmanaged([]u8) = .{},

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
        self.lock.lockSharedUncancelable(self.io);
        if (self.docs.get(slug)) |cached| {
            self.lock.unlockShared(self.io);
            return cached;
        }
        self.lock.unlockShared(self.io);

        const doc = self.manifest.get(slug) orelse return error.NotFound;
        const body = try self.loadDocument(doc);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.docs.get(slug)) |cached| {
            self.allocator.free(body);
            return cached;
        }
        const key = try self.allocator.dupe(u8, slug);
        errdefer self.allocator.free(key);
        try self.docs.put(self.allocator, key, body);
        return body;
    }

    pub fn prefetch(self: *BlogCache, slugs: []const []const u8) void {
        for (slugs) |slug| {
            self.lock.lockSharedUncancelable(self.io);
            const cached = self.docs.contains(slug);
            self.lock.unlockShared(self.io);
            if (cached) continue;
            _ = self.getDocument(slug) catch continue;
        }
    }

    fn loadDocument(self: *BlogCache, doc: *const DocumentEntry) ![]u8 {
        const chunk = for (self.manifest.data.chunks) |c| {
            if (c.id == doc.chunk) break c;
        } else return error.ChunkNotFound;

        const bytes = try self.getChunk(chunk.file);
        if (doc.offset + doc.length > bytes.len) return error.InvalidOffset;
        return try self.allocator.dupe(u8, bytes[doc.offset..][0..doc.length]);
    }

    fn getChunk(self: *BlogCache, file: []const u8) ![]const u8 {
        self.lock.lockSharedUncancelable(self.io);
        if (self.chunks.get(file)) |cached| {
            self.lock.unlockShared(self.io);
            return cached;
        }
        self.lock.unlockShared(self.io);

        const bytes = try self.cdn.fetchChunk(file);

        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.chunks.get(file)) |cached| {
            self.allocator.free(bytes);
            return cached;
        }
        const key = try self.allocator.dupe(u8, file);
        errdefer self.allocator.free(key);
        try self.chunks.put(self.allocator, key, bytes);
        return bytes;
    }
};
