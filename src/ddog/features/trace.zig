const std = @import("std");
const http = std.http;
const Agent = @import("../internals/agent.zig");
const chroma_logger = @import("chroma");
const ddog = std.log.scoped(.ddog_log);
const Tardy = @import("tardy");
const getStatusError = @import("../common/status.zig").getStatusError;
const GenericBatchWriter = @import("../internals/batcher.zig").GenericBatchWriter;
const Utils = @import("../internals/utils.zig");
const PayloadResult = struct {
    data: []u8,
    needs_free: bool,
};

pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};

pub const SpanType = enum {
    web,
    db,
    cache,
    custom,

    pub fn toPhrase(trace_type: SpanType) []const u8 {
        return switch (trace_type) {
            .web => "web",
            .db => "db",
            .cache => "cache",
            .custom => "custom",
        };
    }
};

pub const Span = struct {
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
    type: ?SpanType = .custom,
};

pub const Trace = []Span;

pub const TraceSubmissionOptions = struct {
    compressible: bool = false,
    batched: bool = false,
    batcher: ?*GenericBatchWriter = null,
    compression_level: std.compress.gzip.Options = .{ .level = .fast },
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

pub fn submitTraces(self: *Agent.DdogClient, traces: []Trace, opts: TraceSubmissionOptions) !Agent.Result {
    const allocator = self.allocator;
    var headers = try prepareHeaders(allocator, self.api_key);
    defer headers.deinit();

    const json_payload = try Utils.serialize([]Trace, allocator, traces);
    defer allocator.free(json_payload);

    const payload = try compressPayloadIfNecessary(allocator, json_payload, traces, opts.compression_level);
    defer if (payload.needs_free) allocator.free(payload.data);
    var request = try sendTracesRequest(self.http_client, headers.items, payload.data);
    defer request.deinit();
    if (opts.batched) {
        if (opts.batcher) |batcher| {
            var out = std.ArrayList(u8).init(self.allocator);
            try std.json.stringify(
                traces,
                .{
                    .emit_nonportable_numbers_as_strings = true,
                    .escape_unicode = true,
                    .emit_null_optional_fields = true,
                    .emit_strings_as_arrays = false,
                },
                out.writer(),
            );
            try out.append('\n');
            try batcher.log(try out.toOwnedSlice());
        }
    }

    return processTraceResponse(allocator, &request);
}

fn prepareHeaders(allocator: std.mem.Allocator, api_key: []const u8) !std.ArrayList(http.Header) {
    var headers = std.ArrayList(http.Header).init(allocator);
    errdefer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = api_key });
    return headers;
}

fn compressPayloadIfNecessary(allocator: std.mem.Allocator, payload: []u8, traces: []Trace, compression_level: std.compress.gzip.Options) !PayloadResult {
    if (traces.len <= 20) {
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

    return .{
        .data = try out.toOwnedSlice(),
        .needs_free = false,
    };
}

fn sendTracesRequest(http_client: *std.http.Client, headers: []http.Header, payload: []const u8) !std.http.Client.Request {
    const server_header_buffer = try http_client.allocator.alloc(u8, 4096);
    errdefer http_client.allocator.free(server_header_buffer);
    var request = try http_client.open(.PUT, try std.Uri.parse("http://localhost:8126/v0.3/traces"), .{
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
        const err = getStatusError(status);
        return .{ body, err };
    }
    const body: []const u8 = request.reader().readAllAlloc(
        allocator,
        std.math.maxInt(i64),
    ) catch unreachable;

    return .{ body, null };
}
