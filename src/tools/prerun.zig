const std = @import("std");
const libraries = @import("libraries");
const fs = libraries.fs;
const pg = @import("pg");
const config_mod = @import("../app/config.zig");

const Manifest = libraries.processor.documents.manifest.Manifest;

fn applySqlFile(pool: *pg.Pool, allocator: std.mem.Allocator, path: []const u8) !void {
    const bytes = try fs.cwd().readFileAlloc(
        allocator,
        path,
        4 * 1024 * 1024,
    );
    defer allocator.free(bytes);
    _ = try pool.exec(bytes, .{});
    std.log.info("applied {s}", .{path});
}

fn upsertBlogs(pool: *pg.Pool, allocator: std.mem.Allocator, pack_dir: []const u8) !void {
    var dir = fs.cwd().openDir(pack_dir, .{}) catch |err| {
        std.log.err("cannot open blog pack dir '{s}': {}", .{ pack_dir, err });
        std.log.err("run `zig build pack` to generate packed markdown and manifest.json", .{});
        return err;
    };
    defer dir.close();
    var manifest = try Manifest.load(
        allocator,
        dir,
        "manifest.json",
    );
    defer manifest.deinit();

    for (manifest.data.documents) |doc| {
        _ = try pool.exec(
            \\insert into blogs (slug, path)
            \\values ($1, $2)
            \\on conflict (slug) do update set path = excluded.path
        ,
            .{ doc.slug, doc.path },
        );
    }
    std.log.info("upserted {d} blog rows", .{manifest.data.documents.len});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var loaded = try config_mod.load(allocator, ".env");
    defer loaded.deinit();
    const cfg = loaded.config;

    const uri = try std.Uri.parse(cfg.db.url);
    var pool = pg.Pool.initUri(io, allocator, uri, .{ .size = 2 }) catch |err| {
        std.log.err("failed to connect to postgres at {s}: {}", .{ cfg.db.url, err });
        std.log.err("start it with `docker compose up -d postgres`, then retry", .{});
        return err;
    };
    defer pool.deinit();

    const sql_files = [_][]const u8{
        "sql/001_blogs.sql",
        "sql/002_comments.sql",
        "sql/003_replies.sql",
    };
    for (sql_files) |path| {
        try applySqlFile(pool, allocator, path);
    }

    try upsertBlogs(pool, allocator, cfg.blog.pack_dir);
    std.log.info("prerun complete", .{});
}
