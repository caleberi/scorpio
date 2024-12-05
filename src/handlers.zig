const std = @import("std");
const zzz = @import("zzz");
const Agent = @import("./ddog/internals/agent.zig");
const Features = @import("./ddog/features/index.zig");
const zhttp = zzz.HTTP;
const Server = zhttp.Server(.plain);
const Router = Server.Router;
const Route = Server.Route;
const Context = Server.Context;
const Trace = Features.trace.Trace;
const GenericBatchWriter = @import("./ddog/internals//batcher.zig").GenericBatchWriter;

pub const Dependencies = struct {
    env: *std.process.EnvMap,
    ddog: *Agent.DdogClient,
    tracer: *GenericBatchWriter(Trace),
};

pub fn KillHandler(ctx: *Context, _: void) !void {
    ctx.runtime.stop();
    std.process.exit(0);
}

pub fn traceHandler(ctx: *Context, deps: *Dependencies) !void {
    if (!std.mem.eql(u8, ctx.request.headers.get("content-type").?, "application/json")) {
        return ctx.respond(.{
            .status = .@"Bad Request",
            .mime = zhttp.Mime.JSON,
            .body = "{\"success\": false, \"message\":\"Bad request.\"}",
        });
    }

    const data = ctx.allocator.dupe(u8, ctx.request.body) catch return ctx.response.set(.{
        .status = .OK,
        .mime = zhttp.Mime.JSON,
        .body = "{\"success\": false, \"message\":\"Something went wrong.\"}",
    });
    defer ctx.allocator.free(data);

    const parsed_trace: std.json.Parsed([]Trace) = std.json.parseFromSlice([]Trace, ctx.allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch return ctx.respond(.{
        .status = .@"Internal Server Error",
        .mime = zhttp.Mime.JSON,
        .body = "{\"success\": false, \"message\":\"Something went wrong.\"}",
    });

    defer parsed_trace.deinit();
    const ddog: *Agent.DdogClient = deps.ddog;
    const tracer: *GenericBatchWriter(Features.trace.Trace) = deps.tracer;

    const result: Agent.Result = ddog.sendTrace(parsed_trace.value, .{
        .logger = tracer,
        .compressible = true,
        .compression_type = .{ .level = .best },
    }) catch return ctx.respond(.{
        .status = .@"Internal Server Error",
        .mime = zhttp.Mime.JSON,
        .body = "{\"success\": false, \"message\":\"Something went wrong.\"}",
    });

    return ctx.respond(.{
        .status = .OK,
        .mime = zhttp.Mime.JSON,
        .body = result.@"0",
    });
}

pub fn logHandler(ctx: *Context, deps: *Dependencies) !void {
    _ = ctx;
    _ = deps;
}

pub fn metricHandler(ctx: *Context, deps: *Dependencies) !void {
    _ = ctx;
    _ = deps;
}
