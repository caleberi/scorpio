const std = @import("std");
const libraries = @import("libraries");
const config_mod = @import("../app/config.zig");
const fs = libraries.fs;
const images = libraries.processor.images;
const videos = libraries.processor.videos;

const Cloudinary = libraries.uploader.cloudinary.Cloudinary;
const Directory = libraries.processor.documents.loader.Directory;
const Packer = libraries.processor.documents.packer.Packer;
const Manifest = libraries.processor.documents.manifest.Manifest;

const UploadState = struct {
    chunks: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *UploadState) void {
        self.chunks.deinit(self.arena.child_allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    fn load(allocator: std.mem.Allocator, pack_dir: []const u8) !UploadState {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var state: UploadState = .{ .arena = arena, .chunks = .{} };
        const path = try fs.path.join(allocator, &.{ pack_dir, ".upload-state.json" });
        defer allocator.free(path);

        const bytes = fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound, error.Unexpected => return state,
            else => return err,
        };
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return state;
        const chunks_val = parsed.value.object.get("chunks") orelse return state;
        if (chunks_val != .object) return state;

        var it = chunks_val.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            const key = try state.arena.allocator().dupe(u8, entry.key_ptr.*);
            const val = try state.arena.allocator().dupe(u8, entry.value_ptr.string);
            try state.chunks.put(allocator, key, val);
        }
        return state;
    }

    fn save(self: *UploadState, allocator: std.mem.Allocator, pack_dir: []const u8) !void {
        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(allocator);

        var chunks_obj: std.json.ObjectMap = .empty;
        defer chunks_obj.deinit(allocator);

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            try chunks_obj.put(allocator, entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try obj.put(allocator, "chunks", .{ .object = chunks_obj });

        const rendered = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{ .whitespace = .indent_2 });
        defer allocator.free(rendered);

        try fs.cwd().makePath(pack_dir);
        const path = try fs.path.join(allocator, &.{ pack_dir, ".upload-state.json" });
        defer allocator.free(path);
        try fs.cwd().writeFile(.{ .sub_path = path, .data = rendered });
    }
};

fn ensureDir(path: []const u8) !void {
    try fs.cwd().makePath(path);
}

fn publicId(allocator: std.mem.Allocator, prefix: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, file });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var loaded = try config_mod.load(allocator, ".env");
    defer loaded.deinit();
    const cfg = loaded.config;

    try ensureDir(cfg.blog.staging_dir);
    try ensureDir(cfg.blog.pack_dir);

    var cloud = Cloudinary.init(
        allocator,
        io,
        cfg.cloudinary.cloudname,
        cfg.cloudinary.api_key,
        cfg.cloudinary.api_secret,
    );
    defer cloud.deinit();

    {
        var img = images.init(allocator, .{
            .input_dir = cfg.blog.input_dir,
            .output_dir = cfg.blog.staging_dir,
            .asset_root = cfg.blog.input_dir,
            .public_id_prefix = cfg.cloudinary.pack_prefix,
        }, &cloud);
        defer img.deinit();
        try img.run();
    }
    {
        var vid = videos.init(allocator, .{
            .input_dir = cfg.blog.staging_dir,
            .output_dir = cfg.blog.staging_dir,
            .asset_root = cfg.blog.input_dir,
            .public_id_prefix = cfg.cloudinary.pack_prefix,
        }, &cloud);
        defer vid.deinit();
        try vid.run();
    }

    var directory = try Directory.load(allocator, cfg.blog.staging_dir);
    defer directory.deinit();

    var packer = Packer.init(allocator, .{
        .output_dir = cfg.blog.pack_dir,
    }, &directory);
    defer packer.deinit();
    try packer.pack();

    var upload_state = try UploadState.load(allocator, cfg.blog.pack_dir);
    defer upload_state.deinit();

    var pack_dir = try fs.cwd().openDir(cfg.blog.pack_dir, .{});
    defer pack_dir.close();

    var manifest = try Manifest.load(allocator, pack_dir, "manifest.json");
    defer manifest.deinit();

    for (manifest.data.chunks) |chunk| {
        const prev = upload_state.chunks.get(chunk.file);
        const changed = prev == null or !std.mem.eql(u8, prev.?, chunk.sha256);
        if (!changed) continue;

        const local_path = try fs.path.join(allocator, &.{ cfg.blog.pack_dir, chunk.file });
        defer allocator.free(local_path);
        const pid = try publicId(allocator, cfg.cloudinary.pack_prefix, chunk.file);
        defer allocator.free(pid);

        std.log.info("uploading packed chunk {s}", .{chunk.file});
        var uploaded = cloud.uploadFile(local_path, .{
            .resource_type = .raw,
            .public_id = pid,
            .overwrite = true,
            .invalidate = true,
        }) catch |err| {
            std.log.warn("chunk upload skipped for {s}: {}", .{ chunk.file, err });
            continue;
        };
        defer uploaded.deinit();

        const key = try upload_state.arena.allocator().dupe(u8, chunk.file);
        const val = try upload_state.arena.allocator().dupe(u8, chunk.sha256);
        try upload_state.chunks.put(allocator, key, val);
    }

    {
        const manifest_path = try fs.path.join(allocator, &.{ cfg.blog.pack_dir, "manifest.json" });
        defer allocator.free(manifest_path);
        const pid = try publicId(allocator, cfg.cloudinary.pack_prefix, "manifest.json");
        defer allocator.free(pid);
        std.log.info("uploading manifest.json", .{});
        var uploaded = cloud.uploadFile(manifest_path, .{
            .resource_type = .raw,
            .public_id = pid,
            .overwrite = true,
            .invalidate = true,
        }) catch |err| {
            std.log.warn("manifest upload skipped: {}", .{err});
            try upload_state.save(allocator, cfg.blog.pack_dir);
            std.log.info("pack complete (local artifacts ready): {d} documents, {d} chunks", .{
                manifest.data.documents.len,
                manifest.data.chunks.len,
            });
            return;
        };
        defer uploaded.deinit();
    }

    try upload_state.save(allocator, cfg.blog.pack_dir);
    std.log.info("pack complete: {d} documents, {d} chunks", .{
        manifest.data.documents.len,
        manifest.data.chunks.len,
    });
}
