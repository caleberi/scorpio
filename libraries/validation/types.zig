const zstd = @import("std");

/// A single positional argument for a validator rule (`@min=18`, `@endswith=".com"`).
/// Extra arguments are further slice entries, not a named map.
pub const Parameter = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,

    pub fn asString(self: Parameter) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: Parameter) ?i64 {
        return switch (self) {
            .int => |i| i,
            .string => |s| zstd.fmt.parseInt(i64, s, 10) catch null,
            .float => |f| blk: {
                if (f != @floor(f)) break :blk null;
                break :blk @intFromFloat(f);
            },
            else => null,
        };
    }

    pub fn asFloat(self: Parameter) ?f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .string => |s| zstd.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn asBool(self: Parameter) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn dupe(self: Parameter, allocator: zstd.mem.Allocator) !Parameter {
        return switch (self) {
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            else => self,
        };
    }

    pub fn deinit(self: Parameter, allocator: zstd.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
};

/// A field value presented to a validator. `.other` is unconverted input.
pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    other,

    pub fn fromAny(value: anytype) Value {
        const info = @typeInfo(@TypeOf(value));
        return switch (info) {
            .int, .comptime_int => .{ .int = @intCast(value) },
            .float, .comptime_float => .{ .float = @floatCast(value) },
            .bool => .{ .boolean = value },
            .pointer => |ptr| blk: {
                if (ptr.size == .slice and ptr.child == u8) {
                    break :blk .{ .string = value };
                }
                break :blk .other;
            },
            else => .other,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .string => |s| zstd.fmt.parseInt(i64, s, 10) catch null,
            .float => |f| blk: {
                if (f != @floor(f)) break :blk null;
                break :blk @intFromFloat(f);
            },
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .string => |s| zstd.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }
};
