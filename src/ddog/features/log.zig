const std = @import("std");
const http = std.http;
const Agent = @import("./agent.zig");
const chroma_logger = @import("chroma");
pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};
const ddog = std.log.scoped(.ddog_log);
const Tardy = @import("tardy");
const Runtime = Tardy.Runtime;
const Task = Tardy.Task;
const getStatusError = @import("./common/status.zig").getStatusError;

pub const Log = struct {
    message: []const u8,
    service: []const u8,
    status: []const u8,
    ddsource: []const u8,

    ddtags: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
};

pub const LogOpts = struct {
    compressible: bool = false,
    batched: bool = false,
    compression_type: std.compress.gzip.Options = .{ .level = .fast },
};

pub fn submitLog(self: *Agent.DataDogClient, log: Agent.Log, opts: Agent.LogOpts) !Agent.Result {
    if (opts.batched) {
        try self.log_batcher.batch(log);
        const msg: []const u8 = "Successfully batched log for later submission";
        return .{ msg[0..], null };
    }
    var headers = std.ArrayList(http.Header).init(self.allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = self.api_key });
    const uri = try std.fmt.allocPrint(self.allocator, "{s}/api/v2/logs", .{self.host});
    defer self.allocator.free(uri);

    var out = std.ArrayList(u8).init(self.allocator);
    defer out.deinit();

    try std.json.stringify(log, .{}, out.writer());
    var payload = try out.toOwnedSlice();
    if (opts.compressible) {
        try headers.append(.{ .name = "Content-Encoding", .value = "gzip" });
        var fbs = std.io.fixedBufferStream(payload);
        out.clearAndFree();
        var cmp = try std.compress.gzip.compressor(out.writer(), .{ .level = opts.compressible });
        try cmp.compress(fbs.reader());
        try cmp.flush();
        payload = try out.toOwnedSlice();
    }

    const headers_slice: []http.Header = try headers.toOwnedSlice();
    const url = try std.Uri.parse(uri);
    const server_header_buffer = try self.allocator.alloc(u8, 4096);
    defer self.allocator.free(server_header_buffer);
    var request = try self.http_client.open(.POST, url, .{
        .extra_headers = headers_slice,
        .server_header_buffer = server_header_buffer,
    });
    defer request.deinit();
    request.transfer_encoding.content_length = payload.len;
    try request.send();
    try request.writeAll(payload);
    try request.finish();
    try request.wait();

    const response = request.response;
    const status: http.Status = response.status;
    var body: []const u8 = undefined;
    if (status != .accepted) {
        body = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
        ddog.err("[{any}] error={s}", .{ status, body });
        const err = getStatusError(status);
        // remember to deallocate using allocator
        return .{ body, err };
    }
    body = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
    return .{ body, null };
}

pub fn aggregateLog(self: *Agent.DataDogClient, event: Agent.AggregateLogEvent) !void {
    var headers = std.ArrayList(http.Header).init(self.allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = self.api_key });
    const uri = try std.fmt.allocPrint(self.allocator, "{s}/api/v2/logs/analytics/aggregate", .{self.host});
    defer self.allocator.free(uri);

    var out = std.ArrayList(u8).init(self.allocator);
    defer out.deinit();

    try std.json.stringify(event, .{}, out.writer());
    const payload = try out.toOwnedSlice();
    const headers_slice: []http.Header = try headers.toOwnedSlice();
    var request = try self.http_client.open(.POST, uri, headers_slice, .{});
    defer request.deinit();
    request.transfer_encoding.content_length = payload.len;
    try request.send();
    try request.writeAll(payload);
    try request.finish();
    try request.wait();

    const response = request.response;
    const status: http.Status = response.status;
    var body = undefined;
    if (status != .accepted) {
        body = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
        ddog.err("[{s}] error={s}", .{ status, body });
        const err = getStatusError(status);
        // remember to deallocate using allocator
        return .{ body, err };
    }
    body = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
    return .{ body, null };
}
