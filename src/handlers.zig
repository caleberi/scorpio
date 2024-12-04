const std = @import("std");
const zzz = @import("zzz");
const Agent = @import("./ddog/agent.zig");
const zhttp = zzz.HTTP;
const Server = zhttp.Server(.plain);
const Router = Server.Router;
const Route = Server.Route;
const Context = Server.Context;
const Trace = Agent.Trace;
const GenericBatchWriter = @import("./ddog/batcher.zig").GenericBatchWriter;

pub const Dependencies = struct {
    env: *std.process.EnvMap,
    ddog: *Agent.DataDogClient,
    tracer: *GenericBatchWriter(Trace),
};

pub fn KillHandler(ctx: *Context, _: void) !void {
    ctx.runtime.stop();
    std.process.exit(0);
}

pub fn TraceHandler(ctx: *Context, deps: *Dependencies) !void {
    if (!std.mem.eql(u8, ctx.request.headers.get("content-type").?, "application/json")) {
        return ctx.respond(.{ .status = .@"Bad Request", .mime = zhttp.Mime.JSON, .body = null });
    }

    const data = ctx.allocator.dupe(u8, ctx.request.body) catch return ctx.response.set(.{ .status = .OK, .mime = zhttp.Mime.JSON, .body = "something went wrong" });
    defer ctx.allocator.free(data);

    const parsed_trace: std.json.Parsed(Trace) = std.json.parseFromSlice(Trace, ctx.allocator, data, .{ .ignore_unknown_fields = true }) catch return ctx.respond(.{
        .status = .OK,
        .mime = zhttp.Mime.HTML,
        .body = "error passing json",
    });

    defer parsed_trace.deinit();
    const trace = parsed_trace.value;
    const ddog: *Agent.DataDogClient = deps.ddog;
    const tracer: *GenericBatchWriter(Agent.Trace) = deps.tracer;

    const result: Agent.Result = ddog.sendTrace(trace, .{
        .batched = true,
        .batcher = tracer,
        .compressible = true,
        .compression_type = .{ .level = .best },
    }) catch return ctx.respond(.{
        .status = .OK,
        .mime = zhttp.Mime.HTML,
        .body = "cannot send trace",
    });

    return ctx.respond(.{
        .status = .OK,
        .mime = zhttp.Mime.TEXT,
        .body = result.@"0",
    });
}
