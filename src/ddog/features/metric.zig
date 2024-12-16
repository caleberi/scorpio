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

pub const MetricType = enum(u8) {
    Unspecified = 0,
    Count = 1,
    Rate = 2,
    Gauge = 3,

    pub fn toString(metric_type: MetricType) []const u8 {
        return switch (metric_type) {
            .Unspecified => "unspecified",
            .Count => "count",
            .Rate => "rate",
            .Gauge => "gauge",
        };
    }
};

pub const Metric = struct {
    series: []struct {
        interval: i64,
    },
    metadata: struct {
        origin: struct {
            metric_type: i32,
            product: i32,
            service: i32,
        },
        metric: []const u8,
    },
    points: []struct {
        timestamp: i64,
        value: f64,
    },
    resources: struct {
        name: []const u8,
        source_type_name: []u8,
        tags: []const u8,
        type: MetricType,
        unit: []const u8,
    },
};

pub const MetricSubmissionOptions = struct {
    compressible: bool = false,
    batched: bool = false,
    batcher: ?*GenericBatchWriter = null,
    compression_level: std.compress.gzip.Options = .{ .level = .fast },
};

const MetricSubmissionError = error{
    NetworkError,
    CompressionError,
    RequestError,
    OutOfMemory,
    UnfinishedBits,
    UnexpectedCharacter,
    InvalidFormat,
    InvalidPort,
};

pub fn submitMetrics(self: *Agent.DdogClient, metrics: []Metric, opts: MetricSubmissionOptions) !Agent.Result {
    const allocator = self.allocator;
    var headers = try prepareHeaders(allocator, self.api_key);
    defer headers.deinit();

    const json_payload = try Utils.serialize([]Metric, allocator, metrics);
    defer allocator.free(json_payload);

    const payload = try compressPayloadIfNecessary(allocator, json_payload, metrics, opts.compression_level);
    defer if (payload.needs_free) allocator.free(payload.data);

    var request = try sendMetricsRequest(self.http_client, headers.items, payload.data);
    defer request.deinit();

    if (opts.batched) {
        if (opts.batcher) |batcher| {
            var out = std.ArrayList(u8).init(self.allocator);
            try std.json.stringify(
                metrics,
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

    return processMetricResponse(allocator, &request);
}

fn prepareHeaders(allocator: std.mem.Allocator, api_key: []const u8) !std.ArrayList(http.Header) {
    var headers = std.ArrayList(http.Header).init(allocator);
    errdefer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = api_key });
    return headers;
}

fn compressPayloadIfNecessary(allocator: std.mem.Allocator, payload: []u8, metrics: []Metric, compression_level: std.compress.gzip.Options) !PayloadResult {
    if (metrics.len <= 20) {
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
        .needs_free = true,
    };
}

fn sendMetricsRequest(http_client: *std.http.Client, headers: []http.Header, payload: []const u8) !std.http.Client.Request {
    const server_header_buffer = try http_client.allocator.alloc(u8, 4096);
    errdefer http_client.allocator.free(server_header_buffer);

    var request = try http_client.open(.PUT, try std.Uri.parse("http://localhost:8126/v0.3/metrics"), .{
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

fn processMetricResponse(allocator: std.mem.Allocator, request: *std.http.Client.Request) !Agent.Result {
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
