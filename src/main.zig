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
const ArgsParser = @import("args");
const Agent = @import("./ddog/agent.zig");
const chroma_logger = @import("chroma");
const rrouter = @import("router.zig");
const TracerBatchWriter = Agent.TracerBatchWriter;
const LogBatchWriter = Agent.LogBatchWriter;
const assert = std.debug.assert;
const Server = zhttp.Server(.plain, .busy_loop);

const time = std.time;
pub const std_options = .{
    .log_level = .debug,
    .logFn = appLogFn,
};
const scorpio_log = std.log.scoped(.scorpio);

pub const Args = struct {
    file: ?[]const u8 = "",
    @"error-log": ?[]const u8 = "",

    pub fn format(self: Args, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const fmt_str: []const u8 = "Args [.file = '{s}', .error-log = '{s}']";
        _ = try writer.print(fmt_str, .{ self.file orelse "", self.@"error-log" orelse "" });
    }
};

var running = std.atomic.Value(bool).init(true);

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

pub fn main() !void {

    // TODO:  Understand how to use async runtime to do
    // some work all around the application

    // TODO: Add gracefully shutdown to the  application to clean up resources
    // TODO: Handle app configuration
    // TODO: Handle how application can be registered to log information without
    // blocking via datadog application API via streaming / http request

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() != .ok) {
            _ = gpa.detectLeaks();
        }
    }

    const args = try ArgsParser.parseForCurrentProcess(Args, allocator, .print);
    defer args.deinit();

    scorpio_log.info("{any}", .{args.options});
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const env_map = try load_environment(arena.allocator(), args.options.file.?);
    defer env_map.deinit();

    const port = std.fmt.parseInt(u16, env_map.get("APP_PORT").?, 10) catch 9090;
    const host = env_map.get("APP_HOST").?;
    const thread_count = @max(@as(u16, @intCast(try std.Thread.getCpuCount() / 2 - 1)), 1);
    const connection_per_thread = try std.math.divCeil(u16, 2500, thread_count);

    const api_key = env_map.get("DD_API_KEY").?;
    const api_site = env_map.get("DD_SITE").?;

    const datadog_client = try allocator.create(Agent.DataDogClient);
    datadog_client.* = try Agent.DataDogClient.init(allocator, api_key, api_site);
    defer datadog_client.*.deinit();
    defer allocator.destroy(datadog_client);

    var server = Server.init(.{
        .allocator = allocator,
        .threading = .auto,
        .size_connections_max = connection_per_thread,
    });

    var router = zhttp.Router.init(
        arena.allocator(),
        &.{ env_map, datadog_client },
    );
    defer router.deinit();

    try rrouter.bindRoutes(&router);

    if (@import("config").@"os-tag" == .linux) {
        _ = clib.ddprof_start_profiling();
        defer clib.ddprof_stop_profiling(5000);
    }

    defer server.deinit();

    const signals = [_]c_int{ clib.SIGINT, clib.SIGTERM };
    for (signals) |sig| {
        _ = clib.sigaction(sig, &.{
            .__sigaction_u = .{ .__sa_handler = signalHandler },
            .sa_mask = clib.SV_NODEFER,
            .sa_flags = 0,
        }, null);
    }

    try server.bind(host, @intCast(port));
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *zhttp.Server(.plain, .auto), r: *zhttp.Router) !void {
            srv.listen(.{
                .router = r,
                .num_header_max = 32,
                .num_captures_max = 0,
                .size_request_max = 2048,
                .size_request_uri_max = 256,
            }) catch |err| {
                scorpio_log.warn("Stopping server ... {any}", .{err});
            };
        }
    }.run, .{ &server, &router });

    while (running.load(.acquire)) {
        std.time.sleep(std.time.ns_per_s / 10);
    }

    const terminate_endpoint_buf = try allocator.alloc(u8, 256);
    defer allocator.free(terminate_endpoint_buf);
    const terminate_endpoint = try std.fmt.bufPrintZ(terminate_endpoint_buf, "http://{s}:{d}/kill", .{ host, port });
    monitorShutdown(arena.allocator(), terminate_endpoint, 10) catch |err| {
        scorpio_log.err("Error checking server: {any}\n", .{err});
    };
    std.time.sleep(std.time.ns_per_min);
    thread.join();
}

fn appLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // if (scope != .scorpio) return;
    return chroma_logger.timeBasedLog(level, scope, format, args);
}

pub fn monitorShutdown(allocator: std.mem.Allocator, endpoint: []const u8, interval_ms: u64) !void {
    var client = http.Client{
        .allocator = allocator,
    };
    defer client.deinit();
    const uri = try std.Uri.parse(endpoint);
    const header_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(header_buf);
    // TODO: Add better memory management here
    while (true) {
        var req = try client.open(.GET, uri, .{ .server_header_buffer = header_buf });
        defer req.deinit();

        try req.send();
        try req.finish();
        try req.wait();
        time.sleep(time.ns_per_ms * interval_ms);
    }
}
