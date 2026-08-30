const std = @import("std");
const libraries = @import("libraries");
const common = @import("common");
const DocumentEntry = libraries.processor.documents.manifest.DocumentEntry;
const Cloudinary = libraries.uploader.cloudinary.Cloudinary;
const ChunkEntry = libraries.processor.documents.manifest.ChunkEntry;

pub const Cdn = struct {
    allocator: std.mem.Allocator,
    cloud: *Cloudinary,
    pack_prefix: []const u8,
    pack_dir: []const u8,

    pub fn fetchDocument(self: *Cdn, chunks: []const ChunkEntry, doc: *const DocumentEntry) ![]u8 {
        const ChunkIdProbe = struct {
            candidate: u32,
            fn matchesId(this: @This(), id: u32) bool {
                return this.candidate == id;
            }
        };

        const chunk = common.utils.filter(
            ChunkEntry,
            self.allocator,
            chunks,
            ChunkIdProbe{ .candidate = doc.chunk },
            ChunkIdProbe.matchesId,
        ) catch return error.ChunkNotFound;

        const bytes = try self.fetchChunk(chunk.file);
        defer self.allocator.free(bytes);

        if (doc.offset + doc.length > bytes.len)
            return error.InvalidOffset;

        // bytes[doc.offset..][0..doc.length] <==> bytes[doc.offset .. doc.offset + doc.length]
        return try self.allocator.dupe(u8, bytes[doc.offset..][0..doc.length]);
    }

    pub fn fetchChunk(self: *Cdn, file: []const u8) ![]u8 {
        // Prefer local packed artifacts, then fall back to Cloudinary delivery.
        const local_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.pack_dir, file });
        defer self.allocator.free(local_path);

        if (libraries.fs.cwd().readFileAlloc(
            self.allocator,
            local_path,
            256 * 1024 * 1024,
        )) |bytes| {
            return bytes;
        } else |_| {}

        const public_id = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.pack_prefix, file });
        defer self.allocator.free(public_id);

        const url = try self.cloud.deliveryUrl(self.allocator, public_id, .raw, .upload);
        defer self.allocator.free(url);

        var response: std.Io.Writer.Allocating = .init(self.allocator);
        defer response.deinit();

        const res = try self.cloud.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response.writer,
        });
        if (res.status.class() != .success)
            return error.CdnFetchFailed;
        return try self.allocator.dupe(u8, response.written());
    }
};
