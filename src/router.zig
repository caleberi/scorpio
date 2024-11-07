const zzz = @import("zzz");
const zhttp = zzz.HTTP;
const std = @import("std");
const Agent = @import("./ddog/agent.zig");
const Trace = Agent.Trace;

pub fn bindRoutes(router: *zhttp.Router) !void {
    try router.serve_route("/kill", zhttp.Route.init().get(kill_fn));
    try router.serve_route("/", zhttp.Route.init().post(test_fn));
}

fn kill_fn(_: zhttp.Request, response: *zhttp.Response, _: zhttp.Context) void {
    response.set(.{ .status = .Kill, .mime = zhttp.Mime.TEXT, .body = "" });
}

fn test_fn(request: zhttp.Request, response: *zhttp.Response, ctx: zhttp.Context) void {
    if (!std.mem.eql(u8, request.headers.get("content-type").?, "application/json")) {
        return response.set(.{ .status = .@"Bad Request", .mime = zhttp.Mime.JSON, .body = null });
    }

    const data = ctx.allocator.dupe(u8, request.body) catch return response.set(.{ .status = .OK, .mime = zhttp.Mime.JSON, .body = "something went wrong" });
    defer ctx.allocator.free(data);

    const parsed_trace: std.json.Parsed(Trace) = std.json.parseFromSlice(Trace, ctx.allocator, data, .{ .ignore_unknown_fields = true }) catch return response.set(.{
        .status = .OK,
        .mime = zhttp.Mime.HTML,
        .body = "error passing json",
    });

    defer parsed_trace.deinit();
    const trace = parsed_trace.value;
    const ddog = ctx.injector.find(*Agent.DataDogClient);
    if (ddog) |d| {
        const result: Agent.Result = d.sendTrace(trace, .{ .batched = true, .compressible = true, .compression_type = .{ .level = .best } }) catch return response.set(.{
            .status = .OK,
            .mime = zhttp.Mime.HTML,
            .body = "error passing json",
        });

        return response.set(.{
            .status = .OK,
            .mime = zhttp.Mime.JSON,
            .body = result.@"0",
        });
    }

    std.debug.print("{any}", .{trace});

    return response.set(.{
        .status = .OK,
        .mime = zhttp.Mime.HTML,
        .body = "result.@0",
    });
}
