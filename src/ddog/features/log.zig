const std = @import("std");
const http = std.http;
const Agent = @import("../internals/agent.zig");
const getStatusError = @import("../common/status.zig").getStatusError;
const BatchWriter = @import("../internals/batcher.zig").BatchWriter;
const chroma_logger = @import("chroma");
const Request = std.http.Client.Request;
const Utils = @import("../internals/utils.zig");
const PayloadResult = struct {
    data: []u8,
    needs_free: bool,
};

pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};

pub const Log = struct {
    message: ?[]const u8 = null,
    service: ?[]const u8 = null,
    status: ?[]const u8 = null,
    ddsource: ?[]const u8 = null,

    ddtags: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
};

pub const LogSubmissionOptions = struct {
    compressible: bool = false,
    batched: bool = false,
    batcher: ?*BatchWriter = null,
    compression_level: std.compress.gzip.Options = .{ .level = .fast },
};

const BuildRequestResult = struct {
    request: Request,
    header_buffer: []u8,
    headers: *std.ArrayList(http.Header),
    uri: []u8,
};

fn buildRequest(
    allocator: std.mem.Allocator,
    http_client: *http.Client,
    api_key: []const u8,
    site: []const u8,
) !BuildRequestResult {
    var headers = std.ArrayList(http.Header).init(allocator);
    errdefer headers.deinit();
    try headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try headers.append(.{ .name = "DD-API-KEY", .value = api_key });

    const uri = try std.fmt.allocPrint(
        allocator,
        "https://http-intake.logs.{s}/api/v2/logs",
        .{site},
    );
    errdefer allocator.free(uri);

    const headers_slice: []http.Header = try headers.toOwnedSlice();
    const url = try std.Uri.parse(uri);
    const server_header_buffer = try allocator.alloc(u8, 4096);
    errdefer allocator.free(server_header_buffer);

    return BuildRequestResult{
        .headers = &headers,
        .request = try http_client.open(.POST, url, .{
            .extra_headers = headers_slice,
            .server_header_buffer = server_header_buffer,
        }),
        .uri = uri,
        .header_buffer = server_header_buffer,
    };
}

fn compressPayloadIfNecessary(
    allocator: std.mem.Allocator,
    payload: []u8,
    logs: []Log,
    compression_level: std.compress.gzip.Options,
) !PayloadResult {
    if (logs.len <= 50) {
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

pub fn submitLogs(self: *Agent.DdogClient, logs: []Log, opts: LogSubmissionOptions) !Agent.Result {
    var request_builder = try buildRequest(
        self.allocator,
        self.http_client,
        self.api_key,
        self.site,
    );
    defer request_builder.headers.deinit();
    defer self.allocator.free(request_builder.header_buffer);
    defer self.allocator.free(request_builder.uri);

    const json_payload = try Utils.serialize([]Log, self.allocator, logs);
    defer self.allocator.free(json_payload);
    const payload = try compressPayloadIfNecessary(
        self.allocator,
        json_payload,
        logs,
        opts.compression_level,
    );
    defer if (payload.needs_free) self.allocator.free(payload.data);

    var request = request_builder.request;
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = payload.data.len };
    try request.send();
    try request.writeAll(payload.data);
    try request.finish();
    try request.wait();
    if (opts.batched) {
        if (opts.batcher) |batcher| {
            var out = std.ArrayList(u8).init(self.allocator);
            try std.json.stringify(
                logs,
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
    return processLogResponse(self.allocator, &request);
}

fn processLogResponse(allocator: std.mem.Allocator, request: *std.http.Client.Request) !Agent.Result {
    const response = request.response;
    const status: http.Status = response.status;

    if (status != .accepted) {
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
