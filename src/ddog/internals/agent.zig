const std = @import("std");
const json = std.json;
const http = std.http;
const AgentLogger = @import("../features/log.zig");
const AgentTracer = @import("../features/trace.zig");
const AgentMetricRecorder = @import("../features/metric.zig");
const GenericBatchWriter = @import("./batcher.zig").BatchWriter;
const StatusError = @import("../common/status.zig").StatusError;
const Features = @import("../features/index.zig");
const Log = Features.log.Log;
const LogSubmissionOptions = Features.log.LogSubmissionOptions;
const Metric = Features.metric.Metric;
const MetricSubmissionOptions = Features.metric.MetricSubmissionOptions;
const Trace = Features.trace.Trace;
const TraceSubmissionOptions = Features.trace.TraceSubmissionOptions;

pub const Result = std.meta.Tuple(&[_]type{ []const u8, ?StatusError });

pub const DdogClient = struct {
    api_key: []const u8,
    site: []const u8,
    host: []const u8,
    allocator: std.mem.Allocator,
    http_client: *http.Client,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, api_site: []const u8) !Self {
        const buffer = try allocator.alloc(u8, 100);
        defer allocator.free(buffer);
        const site: []u8 = try std.fmt.bufPrint(buffer, "https://api.{s}", .{api_site});
        const client = try allocator.create(http.Client);
        client.* = http.Client{ .allocator = allocator };
        return .{
            .api_key = api_key,
            .allocator = allocator,
            .site = api_site,
            .host = try allocator.dupe(u8, site),
            .http_client = client,
        };
    }

    pub fn deinit(self: *Self) void {
        defer self.allocator.free(self.host);
        defer self.allocator.destroy(self.http_client);
        self.http_client.deinit();
    }

    pub fn submitLog(self: *Self, logs: []Log, opts: LogSubmissionOptions) !Result {
        return try @call(.auto, AgentLogger.submitLogs, .{ self, logs, opts });
    }

    pub fn submitMetric(self: *DdogClient, metric: []Metric, opts: MetricSubmissionOptions) !Result {
        return try @call(.auto, AgentMetricRecorder.submitMetrics, .{ self, metric, opts });
    }

    pub fn sendTrace(self: *Self, traces: []Trace, opts: TraceSubmissionOptions) !Result {
        return try @call(.auto, AgentTracer.submitTraces, .{ self, traces, opts });
    }
};
