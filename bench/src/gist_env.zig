//! Original recursive EnvironmentParser core (gist), parse-from-EnvMap only.
//! File loading / ${VAR} regex resolution omitted so the benchmark compares
//! the same EnvMap→struct path as the FieldPlan rewrite.

const std = @import("std");

pub const EnvironmentError = error{
    InvalidContainer,
    MissingRequiredField,
    TypeConversionError,
};

fn makePrefixedKey(
    allocator: std.mem.Allocator,
    prefix: ?[]const u8,
    name: []const u8,
) ![]u8 {
    if (prefix) |p|
        return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ p, name });
    return try allocator.dupe(u8, name);
}

fn freeField(comptime FieldType: type, allocator: std.mem.Allocator, value: FieldType) void {
    const type_info = @typeInfo(FieldType);
    switch (type_info) {
        .pointer => |ptr| {
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                if (child_info == .@"struct") {
                    free(ptr.child, allocator, value);
                }
            } else if (ptr.size == .slice and ptr.child == u8) {
                allocator.free(value);
            }
        },
        .optional => {
            if (value) |inner| {
                freeField(@TypeOf(inner), allocator, inner);
            }
        },
        else => {},
    }
}

fn duplicateIfNeeded(
    comptime FieldType: type,
    allocator: std.mem.Allocator,
    value: FieldType,
) !FieldType {
    const type_info = @typeInfo(FieldType);
    return switch (type_info) {
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try allocator.dupe(u8, value);
            }
            break :blk value;
        },
        .optional => blk: {
            if (value) |opt_val| {
                const opt_type_info = @typeInfo(@TypeOf(opt_val));
                if (opt_type_info == .pointer) {
                    const ptr_info = opt_type_info.pointer;
                    if (ptr_info.size == .slice and ptr_info.child == u8) {
                        break :blk try allocator.dupe(u8, opt_val);
                    }
                }
                break :blk opt_val;
            }
            break :blk null;
        },
        else => value,
    };
}

fn convertValue(
    comptime FieldType: type,
    allocator: std.mem.Allocator,
    value: []const u8,
) !FieldType {
    const type_info = @typeInfo(FieldType);
    return switch (type_info) {
        .int => std.fmt.parseInt(FieldType, value, 10) catch EnvironmentError.TypeConversionError,
        .float => std.fmt.parseFloat(FieldType, value) catch EnvironmentError.TypeConversionError,
        .bool => blk: {
            const lower = std.ascii.allocLowerString(allocator, value) catch {
                return EnvironmentError.TypeConversionError;
            };
            defer allocator.free(lower);
            if (std.mem.eql(u8, lower, "true") or std.mem.eql(u8, lower, "1")) break :blk true;
            if (std.mem.eql(u8, lower, "false") or std.mem.eql(u8, lower, "0")) break :blk false;
            return EnvironmentError.TypeConversionError;
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                if (value.len > 0) break :blk try allocator.dupe(u8, value);
            }
            return EnvironmentError.TypeConversionError;
        },
        .optional => |opt| blk: {
            if (value.len == 0) break :blk null;
            break :blk try convertValue(opt.child, allocator, value);
        },
        else => EnvironmentError.TypeConversionError,
    };
}

pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    prefix: ?[]const u8,
    environment: std.process.EnvMap,
) !*T {
    @setEvalBranchQuota(100_000);
    const type_info = @typeInfo(T);
    switch (type_info) {
        .pointer => |ptr| {
            if (ptr.size == .one)
                return parse(ptr.child, allocator, prefix, environment);
            return EnvironmentError.InvalidContainer;
        },
        .@"struct" => |struct_info| {
            const container = try allocator.create(T);
            var initialized = [_]bool{false} ** struct_info.fields.len;
            errdefer {
                inline for (struct_info.fields, 0..) |field, i| {
                    if (initialized[i]) {
                        freeField(field.type, allocator, @field(container.*, field.name));
                    }
                }
                allocator.destroy(container);
            }

            inline for (struct_info.fields, 0..) |field, i| {
                const field_type_info = @typeInfo(field.type);

                if (field_type_info == .pointer) {
                    const pointer = field_type_info.pointer;
                    if (pointer.size == .one) {
                        const nested_prefix = try makePrefixedKey(allocator, prefix, field.name);
                        defer allocator.free(nested_prefix);
                        @field(container.*, field.name) = try parse(
                            pointer.child,
                            allocator,
                            nested_prefix,
                            environment,
                        );
                        initialized[i] = true;
                        continue;
                    }
                }

                const env_key = try makePrefixedKey(allocator, prefix, field.name);
                defer allocator.free(env_key);

                var uppercase_key = try allocator.alloc(u8, env_key.len);
                defer allocator.free(uppercase_key);
                uppercase_key = std.ascii.upperString(uppercase_key, env_key);
                const key: []const u8 = uppercase_key[0..env_key.len];

                if (environment.get(key)) |val| {
                    @field(container.*, field.name) = try convertValue(field.type, allocator, val);
                } else if (field.default_value_ptr) |default_ptr| {
                    const default_value = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                    @field(container.*, field.name) = try duplicateIfNeeded(field.type, allocator, default_value);
                } else if (field_type_info == .optional) {
                    @field(container.*, field.name) = null;
                } else {
                    return EnvironmentError.MissingRequiredField;
                }
                initialized[i] = true;
            }

            return container;
        },
        else => return EnvironmentError.InvalidContainer,
    }
}

pub fn free(comptime T: type, allocator: std.mem.Allocator, container: *T) void {
    @setEvalBranchQuota(100_000);
    const type_info_child = @typeInfo(T);
    if (type_info_child != .@"struct") return;
    inline for (type_info_child.@"struct".fields) |field| {
        freeField(field.type, allocator, @field(container.*, field.name));
    }
    allocator.destroy(container);
}

pub fn deinit(comptime T: type, allocator: std.mem.Allocator, container: *T) void {
    free(T, allocator, container);
}
