const std = @import("std");
const clib = @cImport({
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

const pprof = @cImport({
    if (clib.DD_PROF) {
        @cInclude("dd_profiling.h");
    }
});
const zzz = @import("zzz");
const http = std.http;
const zhttp = zzz.HTTP;
const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = zhttp.Server(.plain);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

const ArgsParser = @import("args");
const Agent = @import("./ddog/internals/agent.zig");
const chroma_logger = @import("chroma");
const BatchWriter = @import("./ddog/internals/batcher.zig");
const handlers = @import("handlers.zig");
const Features = @import("./ddog/features/index.zig");
const assert = std.debug.assert;
const time = std.time;
const GenericBatchWriter = BatchWriter.GenericBatchWriter;
const Tracer = GenericBatchWriter([]Features.trace.Trace);
const scorpio_log = std.log.scoped(.scorpio);
pub const std_options = .{
    .log_level = .debug,
    .logFn = appLogFn,
};
var running = std.atomic.Value(bool).init(true);

pub const Args = struct {
    file: ?[]const u8 = "",
    @"error-log": ?[]const u8 = "",

    pub fn format(
        self: Args,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const fmt_str: []const u8 = "Args [.file = '{s}', .error-log = '{s}']";
        _ = try writer.print(fmt_str, .{ self.file orelse "", self.@"error-log" orelse "" });
    }
};

const EntryParams = struct {
    config: *std.process.EnvMap,
    router: *Router,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() != .ok) {
            _ = gpa.detectLeaks();
        }
    }

    const args = try ArgsParser.parseForCurrentProcess(
        Args,
        allocator,
        .silent,
    );
    defer args.deinit();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const env_map = try load_environment(allocator, args.options.file.?);
    defer env_map.deinit();

    const api_key = env_map.get("DD_API_KEY").?;
    const api_site = env_map.get("DD_SITE").?;

    const ddog = try allocator.create(Agent.DdogClient);
    ddog.* = try Agent.DdogClient.init(allocator, api_key, api_site);
    defer ddog.*.deinit();
    defer allocator.destroy(ddog);

    var tracer = try Tracer.init(allocator, "trace.batch");
    const tracer_thd = try backgroundBatcher(
        tracer,
        allocator,
    );

    var loop = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer loop.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    var deps = handlers.Dependencies{ .ddog = ddog, .tracer = tracer, .env = env_map };

    try router.serve_route(
        "/trace",
        Route.init().put(&deps, handlers.traceHandler),
    );
    // try router.serve_route(
    //     "/metric",
    //     Route.init().post(&deps, handlers.metricHandler),
    // );
    // try router.serve_route(
    //     "/log",
    //     Route.init().post(&deps, handlers.logHandler),
    // );

    _ = try std.Thread.spawn(.{}, struct {
        fn run(td: *Tardy, _router: *Router, config: *std.process.EnvMap) !void {
            var params = EntryParams{
                .router = _router,
                .config = config,
            };
            try td.entry(&params, entry, {}, exit);
        }
    }.run, .{ &loop, &router, env_map });

    if (@import("config").@"os-tag" == .linux) {
        _ = clib.ddprof_start_profiling();
        defer clib.ddprof_stop_profiling(5000);
    }

    _ = clib.signal(clib.SIGINT, signalHandler);
    while (running.load(.acquire)) {}

    tracer.shutdown();
    tracer_thd.join();
    std.process.exit(0);
}

fn appLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // if (scope != .scorpio or scope != .batch_writer) return;
    return chroma_logger.timeBasedLog(level, scope, format, args);
}

fn signalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    running.store(false, .release);
    scorpio_log.warn("Received shutdown signal, stopping server...", .{});
}

fn load_environment(allocator: std.mem.Allocator, filepath: []const u8) !*std.process.EnvMap {
    assert(!std.mem.eql(u8, filepath, ""));
    var filename: []const u8 = undefined;
    var dirname: []const u8 = undefined;

    var i: usize = filepath.len - 1;
    while (i > 0) : (i -= 1) {
        if (filepath[i] != '/') continue;
        {
            filename = filepath[i + 1 .. filepath.len];
            dirname = filepath[0..i];
            break;
        }
    }

    var env = try allocator.create(std.process.EnvMap);
    env.* = try std.process.getEnvMap(allocator);
    var dir = try std.fs.openDirAbsolute(dirname, .{ .access_sub_paths = false });
    defer dir.close();
    const file_sz = try dir.statFile(filename);
    const content: []const u8 = try dir.readFileAlloc(allocator, filename, file_sz.size);
    var lines = std.mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var components = std.mem.split(u8, line, "=");
        const key = std.mem.trim(u8, components.next().?, " ");
        const value = std.mem.trim(u8, components.next().?, " ");
        if (!std.mem.eql(u8, key, "")) {
            try env.put(key, value);
        }
    }
    return env;
}

pub fn backgroundBatcher(batch_writer: anytype, allocator: std.mem.Allocator) !*std.Thread {
    const thread = try allocator.create(std.Thread);
    thread.* = try std.Thread.spawn(.{}, struct {
        fn run(b: anytype) !void {
            if (std.meta.hasMethod(@TypeOf(b), "run")) {
                try b.run();
                return;
            }
            @panic("cannot start a batcher without run method");
        }
    }.run, .{
        batch_writer,
    });
    return thread;
}

fn entry(rt: *Runtime, ep: *EntryParams) !void {
    const thread_count = @max(@as(u16, @intCast(try std.Thread.getCpuCount() / 2 - 1)), 1);
    const connection_per_thread = try std.math.divCeil(u16, 2500, thread_count);

    var server = Server.init(.{
        .allocator = rt.allocator,
        .size_connections_max = connection_per_thread,
    });

    const port = std.fmt.parseInt(u16, ep.config.get("APP_PORT").?, 10) catch 9090;
    const host = ep.config.get("APP_HOST").?;
    try server.bind(host, @intCast(port));
    try server.serve(ep.router, rt);
}

fn exit(rt: *Runtime, _: void) !void {
    try Server.clean(rt);
}
