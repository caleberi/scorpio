const std = @import("std");

pub const MetricType = enum(u8) {
    Unspecified = 0,
    Count = 1,
    Rate = 2,
    Gauge = 3,
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
        type: std.meta.Tag(MetricType),
        unit: []const u8,
    },
};
