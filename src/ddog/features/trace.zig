// const std = @import("std");
// const http = std.http;
// const Agent = @import("../internals/agent.zig");
// const chroma_logger = @import("chroma");
// pub const std_options = .{
//     .log_level = .debug,
//     .logFn = chroma_logger.timeBasedLog,
// };
// const ddog = std.log.scoped(.ddog_log);
// const Tardy = @import("tardy");
// const Runtime = Tardy.Runtime;
// const Task = Tardy.Task;
// const getStatusError = @import("../common/status.zig").getStatusError;
// const GenericBatchWriter = @import("../internals/batcher.zig").GenericBatchWriter;

// pub const TraceOpts = struct {
//     compressible: bool = false,
//     logger: ?*GenericBatchWriter([]Trace) = null,
//     compression_type: std.compress.gzip.Options = .{
//         .level = .fast,
//     },
// };

// pub const Trace = struct {
//     duration: i64 = 0,
//     @"error": u8 = 0,
//     meta: ?std.json.Value = null,
//     metrics: ?std.json.Value = null,
//     name: []const u8 = "",
//     parent_id: i64 = 0,
//     resource: []const u8 = "",
//     service: []const u8 = "",
//     span_id: u64 = 0,
//     start: i64 = 0,
//     trace_id: i64 = 0,
//     type: ?TraceType = .custom,

//     const TraceType = enum {
//         web,
//         db,
//         cache,
//         custom,

//         pub fn phrase(trace_type: TraceType) ?[]const u8 {
//             return switch (trace_type) {
//                 .web => "web",
//                 .db => "db",
//                 .cache => "cache",
//                 .custom => "custom",
//                 else => null,
//             };
//         }
//     };
// };

// pub fn submitTrace(self: *Agent.DdogClient, traces: [][]Trace, opts: TraceOpts) !Agent.Result {
//     var headers = std.ArrayList(http.Header).init(self.allocator);
//     defer headers.deinit();
//     try headers.append(.{ .name = "Content-Type", .value = "application/json" });
//     try headers.append(.{ .name = "DD-API-KEY", .value = self.api_key });
//     const uri: []const u8 = "http://localhost:8126/v0.3/traces";
//     var out = std.ArrayList(u8).init(self.allocator);
//     defer out.deinit();
//     try std.json.stringify(traces, .{}, out.writer());
//     var payload: []u8 = try out.toOwnedSlice();

//     if (traces[0].len > 1) {
//         try headers.append(.{ .name = "Content-Encoding", .value = "gzip" });
//         var fbs = std.io.fixedBufferStream(payload);
//         out.clearAndFree();
//         var cmp = try std.compress.gzip.compressor(
//             out.writer(),
//             .{
//                 .level = opts.compression_type.level,
//             },
//         );
//         try cmp.compress(fbs.reader());
//         try cmp.flush();
//         payload = try out.toOwnedSlice();
//     }

//     const headers_slice: []http.Header = try headers.toOwnedSlice();
//     const server_header_buffer = try self.allocator.alloc(u8, 4096);
//     errdefer self.allocator.free(server_header_buffer);
//     var request = try self.http_client.?.open(.POST, try std.Uri.parse(uri), .{
//         .extra_headers = headers_slice,
//         .server_header_buffer = server_header_buffer,
//     });
//     defer request.deinit();
//     request.transfer_encoding = .{ .content_length = payload.len };
//     try request.send();
//     try request.writeAll(payload);
//     try request.finish();
//     try request.wait();

//     for (traces) |trace| {
//         try opts.logger.?.log(trace);
//     }

//     const response = request.response;
//     const status: http.Status = response.status;
//     if (status != .ok) {
//         const body = request.reader().readAllAlloc(
//             self.allocator,
//             std.math.maxInt(i64),
//         ) catch unreachable;
//         ddog.err("[{any}] error={s}", .{ status, body });
//         const err = getStatusError(status);
//         return .{ body, err };
//     }
//     const body: []const u8 = request.reader().readAllAlloc(
//         self.allocator,
//         std.math.maxInt(i64),
//     ) catch unreachable;

//     return .{ body, null };
// }

const std = @import("std");
const http = std.http;
const Agent = @import("../internals/agent.zig");
const chroma_logger = @import("chroma");
const ddog = std.log.scoped(.ddog_log);
const Tardy = @import("tardy");
const getStatusError = @import("../common/status.zig").getStatusError;
const GenericBatchWriter = @import("../internals/batcher.zig").GenericBatchWriter;
const PayloadResult = struct {
    data: []u8,
    needs_free: bool,
};

pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};

pub const TraceType = enum {
    web,
    db,
    cache,
    custom,

    pub fn toPhrase(trace_type: TraceType) []const u8 {
        return switch (trace_type) {
            .web => "web",
            .db => "db",
            .cache => "cache",
            .custom => "custom",
        };
    }
};

pub const Trace = struct {
    duration: i64 = 0,
    @"error": u8 = 0,
    meta: ?std.json.Value = null,
    metrics: ?std.json.Value = null,
    name: []const u8 = "",
    parent_id: i64 = 0,
    resource: []const u8 = "",
    service: []const u8 = "",
    span_id: u64 = 0,
    start: i64 = 0,
    trace_id: i64 = 0,
    type: ?TraceType = .custom,
};

pub const TraceSubmissionOptions = struct {
    compressible: bool = false,
    batched: bool = false,
    batcher: ?*GenericBatchWriter([]Trace) = null,
    compression_level: std.compress.gzip.Options = .{ .level = .fast },
    endpoint: []const u8 = "http://localhost:8126/v0.3/traces",
};

const TraceSubmissionError = error{
    NetworkError,
    CompressionError,
    RequestError,
    OutOfMemory,
    UnfinishedBits,
    UnexpectedCharacter,
    InvalidFormat,
    InvalidPort,
};

pub fn submitTraces(self: *Agent.DdogClient, traces: [][]Trace, opts: TraceSubmissionOptions) !Agent.Result {
    const allocator = self.allocator;
    var headers = try prepareHeaders(allocator, self.api_key);
    defer headers.deinit();
    const json_payload = try serializeTraces(allocator, traces);
    defer allocator.free(json_payload);

    const payload = try compressPayloadIfNecessary(
        allocator,
        json_payload,
        traces,
        opts.compression_level,
    );

    defer if (payload.needs_free) allocator.free(payload.data);
    var request = try sendTracesRequest(
        self.http_client.?,
        opts.endpoint,
        headers.items,
        payload.data,
    );
    defer request.deinit();
    // if (opts.batched) {
    //     if (opts.batcher) |batcher| {
    //         for (traces) |trace_group| {
    //             try batcher.log(trace_group);
    //         }
    //     }
    // }

    return processTraceResponse(allocator, &request);
}

fn prepareHeaders(allocator: std.mem.Allocator, api_key: []const u8) !std.ArrayList(http.Header) {
    var headers = std.ArrayList(http.Header).init(allocator);
    errdefer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = api_key });
    return headers;
}

fn serializeTraces(allocator: std.mem.Allocator, traces: [][]Trace) TraceSubmissionError![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try std.json.stringify(traces, .{}, out.writer());
    return try out.toOwnedSlice();
}

fn compressPayloadIfNecessary(allocator: std.mem.Allocator, payload: []u8, traces: [][]Trace, compression_level: std.compress.gzip.Options) !PayloadResult {
    if (traces[0].len <= 1) {
        return .{
            .data = payload,
            .needs_free = false,
        };
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var fbs = std.io.fixedBufferStream(payload);
    var cmp = try std.compress.gzip.compressor(
        out.writer(),
        compression_level,
    );
    try cmp.compress(fbs.reader());
    try cmp.flush();

    return .{ .data = try out.toOwnedSlice(), .needs_free = true };
}

fn sendTracesRequest(http_client: *std.http.Client, endpoint: []const u8, headers: []http.Header, payload: []const u8) !std.http.Client.Request {
    const server_header_buffer = try http_client.allocator.alloc(u8, 4096);
    errdefer http_client.allocator.free(server_header_buffer);
    var request = try http_client.open(.PUT, try std.Uri.parse(endpoint), .{
        .extra_headers = headers,
        .server_header_buffer = server_header_buffer,
    });
    request.transfer_encoding = .{ .content_length = payload.len };
    try request.send();
    try request.writeAll(payload);
    try request.finish();
    try request.wait();
    return request;
}

fn processTraceResponse(allocator: std.mem.Allocator, request: *std.http.Client.Request) !Agent.Result {
    const response = request.response;
    const status: http.Status = response.status;

    if (status != .ok) {
        const body = request.reader().readAllAlloc(
            allocator,
            std.math.maxInt(i64),
        ) catch unreachable;
        ddog.err("[{any}] error={s}", .{ status, body });
        const err = getStatusError(status);
        return .{ body, err };
    }
    const body: []const u8 = request.reader().readAllAlloc(
        allocator,
        std.math.maxInt(i64),
    ) catch unreachable;

    return .{ body, null };
}
