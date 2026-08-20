const zstd = @import("std");
const zap = @import("zap");
const libraries = @import("libraries");
const fs = libraries.fs;
const pg = @import("pg");
const chroma_logger = @import("chroma");

const config_mod = @import("app/config.zig");
const state_mod = @import("app/state.zig");
const BlogCache = @import("app/blog/cache.zig").BlogCache;
const BlogDb = @import("app/blog/db.zig").BlogDb;
const actions = @import("app/actions/root.zig");

const Manifest = libraries.processor.documents.manifest.Manifest;
const Cloudinary = libraries.uploader.cloudinary.Cloudinary;
const Router = libraries.router.Router;

pub const std_options: zstd.Options = .{
    .log_level = .debug,
    .logFn = chroma_logger.Logger(.{}).log,
};

pub fn main(init: zstd.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var loaded = try config_mod.load(allocator, ".env");
    defer loaded.deinit();

    const cfg = loaded.config;
    const uri = try zstd.Uri.parse(cfg.db.url);

    var pool = pg.Pool.initUri(
        io,
        allocator,
        uri,
        .{ .size = 5 },
    ) catch |err| {
        zstd.log.err("failed to connect to postgres at {s}: {}", .{ cfg.db.url, err });
        zstd.log.err("start it with `docker compose up -d postgres`, then retry", .{});
        return err;
    };
    defer pool.deinit();

    var pack_dir = try fs.cwd().openDir(cfg.blog.pack_dir, .{});
    defer pack_dir.close();

    var app_state: state_mod.State = .{
        .allocator = allocator,
        .io = io,
        .config = cfg,
        .manifest = Manifest.load(
            allocator,
            pack_dir,
            "manifest.json",
        ) catch |err| {
            zstd.log.err("failed to load packed manifest from {s}: {}", .{ cfg.blog.pack_dir, err });
            zstd.log.err("run `zig build pack` before starting the server", .{});
            return err;
        },
        .cloud = Cloudinary.init(
            allocator,
            io,
            cfg.cloudinary.cloudname,
            cfg.cloudinary.api_key,
            cfg.cloudinary.api_secret,
        ),
        .cache = undefined,
        .db = BlogDb.init(pool),
    };
    defer app_state.manifest.deinit();
    defer app_state.cloud.deinit();

    app_state.cache = BlogCache.init(
        allocator,
        io,
        &app_state.cloud,
        cfg.cloudinary.pack_prefix,
        cfg.blog.pack_dir,
        &app_state.manifest,
    );
    defer app_state.cache.deinit();

    state_mod.set(&app_state);

    var app_router = Router.init(allocator);
    defer app_router.deinit();

    try app_router.register(.GET, "/hello", libraries.router.actions.hello.Hello);
    try app_router.register(.GET, "/hello/:name", libraries.router.actions.hello.Hello);

    try app_router.register(.GET, "/blog", actions.blogs.List);
    // Comment routes before document splat so /blog/*slug/comments wins over /blog/*slug.
    try app_router.register(.GET, "/blog/*slug/comments", actions.comments.List);
    try app_router.register(.POST, "/blog/*slug/comments", actions.comments.Create);
    try app_router.register(.PUT, "/blog/*slug/comments/:comment_id", actions.comments.Update);
    try app_router.register(.DELETE, "/blog/*slug/comments/:comment_id", actions.comments.Delete);
    try app_router.register(.POST, "/blog/*slug/comments/:comment_id/replies", actions.replies.Create);
    try app_router.register(.PUT, "/blog/*slug/comments/:comment_id/replies/:reply_id", actions.replies.Update);
    try app_router.register(.DELETE, "/blog/*slug/comments/:comment_id/replies/:reply_id", actions.replies.Delete);
    try app_router.register(.GET, "/blog/*slug", actions.blogs.Get);

    const port: u16 = @intCast(cfg.server.port);
    var listener = zap.HttpListener.init(.{
        .port = port,
        .on_request = app_router.onRequestHandler(),
        .log = true,
    });
    listener.listen() catch |err| {
        zstd.log.err("failed to listen on port {d}: {}", .{ port, err });
        zstd.log.err("is another scorpio instance already running?", .{});
        return err;
    };

    zstd.log.info("scorpio listening on http://127.0.0.1:{d}/blog", .{port});
    zap.start(.{
        .threads = cfg.server.threads,
        .workers = cfg.server.workers,
    });
}
