const std = @import("std");
const net = std.net;
const json = std.json;
const http = std.http;
const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
const Allocator = std.mem.Allocator;
pub const Tardy = @import("tardy").Tardy(.auto);
const AgentLogger = @import("../features/log.zig");
const AgentTracer = @import("../features/trace.zig");
const AgentMetricRecorder = @import("../features/metric.zig");
const GenericBatchWriter = @import("./internals/batcher.zig").GenericBatchWriter;
const StatusError = @import("./common/status.zig").StatusError;
const Features = @import("./features/index.zig");
const Log = Features.log.Log;
const LogOpts = Features.log.LogOpts;
const Metric = Features.metric;
const Trace = Features.trace;
const TraceOpts = Features.trace.TraceOpts;
pub const Result = std.meta.Tuple(&[_]type{ []const u8, ?StatusError });

pub const DataDogClient = struct {
    api_key: []const u8,
    host: []const u8,
    allocator: Allocator,
    http_client: ?http.Client = null,
    tracer: AgentTracer.Tracer,
    const Self = @This();

    pub fn init(allocator: Allocator, api_key: []const u8, api_site: []const u8) !Self {
        const buffer = try allocator.alloc(u8, 100);
        defer allocator.free(buffer);
        const site: []u8 = try std.fmt.bufPrint(buffer, "https://api.{s}", .{api_site});
        return .{
            .api_key = api_key,
            .host = try allocator.dupe(u8, site),
            .allocator = allocator,
            .http_client = http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.?.deinit();
        self.allocator.free(self.host);
    }

    pub fn submitLog(self: *Self, log: Log, opts: LogOpts) !Result {
        return try @call(.auto, AgentLogger.submitLog, .{ self, log, opts });
    }

    pub fn submitMetric(self: *DataDogClient, metric: Metric) !Result {
        return try @call(.auto, AgentMetricRecorder.submitMetric, .{ self, metric });
    }

    pub fn sendTrace(self: *DataDogClient, trace: Trace, opts: TraceOpts) !Result {
        return try @call(.auto, AgentTracer.submitTrace, .{ self, trace, opts });
    }
};
