const std = @import("std");
const net = std.net;
const json = std.json;
const http = std.http;
const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
const Allocator = std.mem.Allocator;
const GenericBatchWriter = @import("batcher.zig").GenericBatchWriter;

pub const TracerBatchWriter = GenericBatchWriter(Trace);
pub const LogBatchWriter = GenericBatchWriter(Log);
pub const Tardy = @import("tardy").Tardy(.auto);
const AgentLogger = @import("logger.zig");
const AgentTracer = @import("tracer.zig");

const StatusError = @import("./common/status.zig").StatusError;
pub const Result = std.meta.Tuple(&[_]type{ []const u8, ?StatusError });
pub const LogOpts = struct {
    compressible: bool = false,
    batched: bool = false,
    compression_type: std.compress.gzip.Options = .{ .level = .fast },
};

pub const Log = struct {
    message: []const u8,
    service: []const u8,
    status: []const u8,
    ddsource: []const u8,

    ddtags: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
};

const Aggregation = enum {
    count,
    cardinality,
    pc75,
    pc90,
    pc95,
    pc98,
    pc99,
    sum,
    min,
    max,
    avg,
    median,
    pub fn phrase(self: Aggregation) ?[]const u8 {
        return switch (self) {
            .count => "count",
            .cardinality => "cardinality",
            .pc75 => "pc75",
            .pc90 => "pc90",
            .pc95 => "pc95",
            .pc98 => "pc98",
            .pc99 => "pc99",
            .sum => "sum",
            .min => "min",
            .max => "max",
            .avg => "avg",
            .median => "median",
            else => null,
        };
    }
};

pub const Type = enum {
    timeseries,
    total,
    pub fn phrase(self: Aggregation) ?[]const u8 {
        return switch (self) {
            .timeseries => "timeseries",
            .total => "total",
            else => null,
        };
    }
};

pub const Compute = struct {
    interval: []const u8,
    metric: []const u8,
    type: Type,
    aggregation: Aggregation,
};

pub const Filter = struct {
    from: ?[]const u8 = null,
    indexes: ?[]const []const u8 = null,
    query: ?[]const u8 = null,
    storage_tier: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

pub const Sort = struct {
    aggregation: Aggregation,
    metric: ?[]const u8 = null,
    order: SortOrder = .asc,
    type: SortType = .alphabetical,

    const SortOrder = enum {
        asc,
        desc,
    };

    const SortType = enum {
        alphabetical,
        measure,
    };
};

pub const GroupBy = struct {
    facet: []const u8,
    histogram: ?Histogram = null,
    limit: i64 = 10,
    missing: ?Missing = null,
    sort: ?Sort = null,
    total: ?Total = null,

    pub const Histogram = struct {
        interval: f64,
        max: f64,
        min: f64,
    };

    pub const Missing = union(enum) {
        string_value: []const u8,
        double_value: f64,
    };

    const Total = union(enum) {
        boolean_value: bool,
        string_value: []const u8,
        double_value: f64,
    };
};

pub const AggregateLogEvent = struct {
    compute: Compute,
    filter: Filter,
    group_by: GroupBy,
    options: struct {
        timeOffset: i64,
        timezone: []const u8,
    },
    page: struct {
        cursor: []const u8,
    },
};

pub const TraceOpts = struct {
    compressible: bool = false,
    batched: bool = false,
    compression_type: std.compress.gzip.Options = .{ .level = .fast },
};

pub const Trace = struct {
    duration: i64 = 0,
    @"error": u8 = 0,
    meta: []const u8,
    metrics: []const u8,
    name: []const u8 = "",
    parent_id: i64 = 0,
    resource: []const u8 = "",
    service: []const u8 = "",
    span_id: u64 = 0,
    start: i64 = 0,
    trace_id: i64 = 0,
    type: ?TraceType = .custom,

    const TraceType = enum {
        web,
        db,
        cache,
        custom,

        pub fn phrase(trace_type: TraceType) ?[]const u8 {
            return switch (trace_type) {
                .web => "web",
                .db => "db",
                .cache => "cache",
                .custom => "custom",
                else => null,
            };
        }
    };
};

pub const DataDogClient = struct {
    api_key: []const u8,
    host: []const u8,
    allocator: Allocator,
    http_client: ?http.Client = null,
    tracer_host: []const u8,
    trace_batcher: *TracerBatchWriter,
    log_batcher: *LogBatchWriter,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: Allocator, api_key: []const u8, api_site: []const u8) !Self {
        const buffer = try allocator.alloc(u8, 100);
        defer allocator.free(buffer);
        const site: []u8 = try std.fmt.bufPrint(buffer, "https://api.{s}", .{api_site});
        var arena = std.heap.ArenaAllocator.init(allocator);
        var tracer_batcher = try TracerBatchWriter.init(arena.allocator(), "trace.batch");
        var log_batcher = try LogBatchWriter.init(arena.allocator(), "log.batch");

        return .{
            .api_key = api_key,
            .host = try allocator.dupe(u8, site),
            .tracer_host = "http://localhost:8126/v0.3/traces",
            .allocator = allocator,
            .http_client = http.Client{ .allocator = allocator },
            .arena = arena,
            .trace_batcher = &tracer_batcher,
            .log_batcher = &log_batcher,
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.?.deinit();
        self.allocator.free(self.host);
        self.trace_batcher.*.deinit();
        self.log_batcher.*.deinit();
        self.arena.deinit();
    }

    // pub fn submitLog(self: *DataDogClient, log: Log, opts: LogOpts) !Result {
    //     return try @call(.auto, AgentLogger.submitLog, .{ self, log, opts });
    // }

    // pub fn aggregateLogEvent(self: *DataDogClient, ale: AggregateLogEvent) !Result {
    //     return try @call(.auto, AgentLogger.aggregateLog, .{ self, ale });
    // }

    pub fn sendTrace(self: *DataDogClient, trace: Trace, opts: TraceOpts) !Result {
        return try @call(.auto, AgentTracer.submitTrace, .{ self, trace, opts });
    }
};
