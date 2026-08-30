const zstd = @import("std");
const libraries = @import("libraries");
const config_mod = @import("config.zig");
const Manifest = libraries.processor.documents.manifest.Manifest;
const DocumentEntry = libraries.processor.documents.manifest.DocumentEntry;
const Cloudinary = libraries.uploader.cloudinary.Cloudinary;

pub const BlogCache = @import("blog/cache.zig").BlogCache;
pub const BlogDb = @import("blog/db.zig").BlogDb;

pub const State = struct {
    allocator: zstd.mem.Allocator,
    io: zstd.Io,
    config: *config_mod.AppConfig,
    manifest: Manifest,
    cloud: Cloudinary,
    cache: BlogCache,
    db: BlogDb,

    pub fn findDocument(self: *const State, slug: []const u8) ?*const DocumentEntry {
        return self.manifest.get(slug);
    }

    pub fn neighborSlugs(self: *const State, slug: []const u8, allocator: zstd.mem.Allocator) ![][]const u8 {
        const n: usize = @intCast(@max(0, self.config.blog.prefetch_neighbors));
        if (n == 0) return try allocator.alloc([]const u8, 0);

        const docs = self.manifest.data.documents;
        var index: ?usize = null;
        for (docs, 0..) |doc, i| {
            if (zstd.mem.eql(u8, doc.slug, slug)) {
                index = i;
                break;
            }
        }
        const idx = index orelse return error.NotFound;

        var list: zstd.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);

        var before: usize = 1;
        while (before <= n and idx >= before) : (before += 1) {
            try list.append(allocator, docs[idx - before].slug);
        }
        var after: usize = 1;
        while (after <= n and idx + after < docs.len) : (after += 1) {
            try list.append(allocator, docs[idx + after].slug);
        }
        return list.toOwnedSlice(allocator);
    }
};
