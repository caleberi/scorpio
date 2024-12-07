const std = @import("std");
const zzz = @import("zzz");
const Agent = @import("./ddog/internals/agent.zig");
const Features = @import("./ddog/features/index.zig");

const zhttp = zzz.HTTP;
const Server = zhttp.Server(.plain);
const Context = Server.Context;
const Trace = Features.trace.Trace;
const GenericBatchWriter = @import("./ddog/internals/batcher.zig").GenericBatchWriter;

const HttpError = error{
    BadRequest,
    ParseError,
    SendError,
};

pub const Dependencies = struct {
    env: *std.process.EnvMap,
    ddog: *Agent.DdogClient,
    tracer: *GenericBatchWriter(Trace),
};

pub fn traceHandler(ctx: *Context, deps: *Dependencies) !void {
    validateContentType(ctx, "application/json") catch |err| {
        return errorResponse(ctx, switch (err) {
            HttpError.BadRequest => .@"Bad Request",
            else => .@"Internal Server Error",
        }, "Invalid content type");
    };

    const data = ctx.allocator.dupe(u8, ctx.request.body) catch |err| {
        std.debug.print("Memory allocation error: {any}\n", .{err});
        return errorResponse(ctx, .@"Internal Server Error", "Memory allocation failed");
    };
    defer ctx.allocator.free(data);

    const parsed_trace = parseJson([][]Trace, ctx.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
        return errorResponse(ctx, switch (err) {
            HttpError.ParseError => .@"Bad Request",
            else => .@"Internal Server Error",
        }, "Failed to parse traces");
    };
    defer parsed_trace.deinit();

    const result = deps.ddog.sendTrace(parsed_trace.value, .{
        .logger = deps.tracer,
        .compressible = true,
        .compression_type = .{ .level = .best },
    }) catch |err| {
        std.debug.print("Trace send error: {any}\n", .{err});
        return errorResponse(ctx, .@"Internal Server Error", "Failed to send traces");
    };

    try successResponse(ctx, result.@"0");
}

pub fn logHandler(ctx: *Context, deps: *Dependencies) !void {
    validateContentType(ctx, "application/json") catch |err| {
        _ = err;
        return errorResponse(ctx, .@"Bad Request", "Invalid content type");
    };
    _ = deps;
}

fn validateContentType(ctx: *Context, expected_content_type: []const u8) !void {
    const content_type = ctx.request.headers.get("content-type") orelse return HttpError.BadRequest;
    if (!std.mem.eql(u8, content_type, expected_content_type)) {
        return HttpError.BadRequest;
    }
}

fn successResponse(ctx: *Context, body: []const u8) !void {
    try ctx.respond(.{
        .status = .OK,
        .mime = zhttp.Mime.JSON,
        .body = body,
    });
}

fn errorResponse(ctx: *Context, status: zhttp.Status, message: []const u8) !void {
    try ctx.respond(.{
        .status = status,
        .mime = zhttp.Mime.JSON,
        .body = try std.fmt.allocPrint(ctx.allocator, "{{\"success\": false, \"message\":\"{s}\"}}", .{message}),
    });
}

fn parseJson(comptime T: type, allocator: std.mem.Allocator, data: []const u8, options: std.json.ParseOptions) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, data, options) catch |err| {
        std.debug.print("JSON parsing error: {any}\n", .{err});
        return HttpError.ParseError;
    };
}
