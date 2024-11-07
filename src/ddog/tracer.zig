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
const GenericBatchWriter = @import("./batcher.zig").GenericBatchWriter;
const getStatusError = @import("./common/status.zig").getStatusError;
const Batcher = GenericBatchWriter(Agent.Trace);

pub fn submitTrace(self: *Agent.DataDogClient, trace: Agent.Trace, opts: Agent.TraceOpts) !Agent.Result {
    if (opts.batched) {
        try self.trace_batcher.batch(trace);
        const msg: []const u8 = "Successfully batched trace for later submission";
        return .{ msg, null };
    }
    var headers = std.ArrayList(http.Header).init(self.allocator);
    defer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = self.api_key });

    const uri = try std.fmt.allocPrint(self.allocator, "{s}/api/v2/logs", .{self.host});
    defer self.allocator.free(uri);

    var out = std.ArrayList(u8).init(self.allocator);
    defer out.deinit();

    try std.json.stringify(trace, .{}, out.writer());
    var payload: []u8 = try out.toOwnedSlice();
    if (opts.compressible) {
        try headers.append(.{ .name = "Content-Encoding", .value = "gzip" });
        var fbs = std.io.fixedBufferStream(payload);
        out.clearAndFree();
        var cmp = try std.compress.gzip.compressor(out.writer(), .{ .level = opts.compression_type.level });
        try cmp.compress(fbs.reader());
        try cmp.flush();
        payload = try out.toOwnedSlice();
    }

    const headers_slice: []http.Header = try headers.toOwnedSlice();
    const server_header_buffer = try self.allocator.alloc(u8, 4096);
    errdefer self.allocator.free(server_header_buffer);
    var request = try self.http_client.?.open(.POST, try std.Uri.parse(uri), .{
        .extra_headers = headers_slice,
        .server_header_buffer = server_header_buffer,
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = payload.len };
    try request.send();
    try request.writeAll(payload);
    try request.finish();
    try request.wait();

    const response = request.response;
    const status: http.Status = response.status;
    if (status != .accepted) {
        const body = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
        ddog.err("[{any}] error={s}", .{ status, body });
        const err = getStatusError(status);
        return .{ body, err };
    }
    const body: []const u8 = request.reader().readAllAlloc(self.allocator, std.math.maxInt(i64)) catch unreachable;
    return .{ body, null };
}
