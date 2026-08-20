const zstd = @import("std");

const LeafDesc = struct {
    path: []const []const u8,
    key: []const u8,
};

const AllocDesc = struct {
    path: []const []const u8,
};

fn joinKey(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    if (prefix.len == 0) return name;
    return prefix ++ "_" ++ name;
}

fn makePrefixedKey(allocator: zstd.mem.Allocator, prefix: ?[]const u8, name: []const u8) ![]u8 {
    if (prefix) |p|
        return try zstd.fmt.allocPrint(allocator, "{s}_{s}", .{ p, name });
    return try allocator.dupe(u8, name);
}

fn fieldTypeByName(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        @setEvalBranchQuota(10000);
        if (comptime zstd.mem.eql(u8, field.name, name))
            return field.type;
    }
    @compileError("field not found: " ++ name);
}

fn fieldInfoByName(comptime T: type, comptime name: []const u8) zstd.builtin.Type.StructField {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime zstd.mem.eql(u8, field.name, name))
            return field;
    }
    @compileError("field not found: " ++ name);
}

fn isNestedStructPtr(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer or type_info.pointer.size != .one)
        return false;
    return @typeInfo(type_info.pointer.child) == .@"struct";
}

fn isOptionalLeaf(comptime FieldType: type) bool {
    return @typeInfo(FieldType) == .optional;
}

fn leafCount(comptime T: type) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            n += leafCount(@typeInfo(field.type).pointer.child);
        } else {
            n += 1;
        }
    }
    return n;
}

fn allocSiteCount(comptime T: type) usize {
    var n: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            n += 1 + allocSiteCount(@typeInfo(field.type).pointer.child);
        }
    }
    return n;
}

fn appendLeaves(
    comptime T: type,
    comptime path_prefix: []const []const u8,
    comptime key_prefix: []const u8,
    comptime out: []LeafDesc,
    comptime start: usize,
) usize {
    var i: usize = start;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const field_path = path_prefix ++ &[_][]const u8{field.name};
        const field_key = joinKey(key_prefix, field.name);
        if (comptime isNestedStructPtr(field.type)) {
            i = appendLeaves(
                @typeInfo(field.type).pointer.child,
                field_path,
                field_key,
                out,
                i,
            );
        } else {
            out[i] = .{
                .path = field_path,
                .key = field_key,
            };
            i += 1;
        }
    }
    return i;
}

fn appendAllocSites(
    comptime T: type,
    comptime path_prefix: []const []const u8,
    comptime out: []AllocDesc,
    comptime start: usize,
) usize {
    var i: usize = start;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isNestedStructPtr(field.type)) {
            const field_path = path_prefix ++ &[_][]const u8{field.name};
            out[i] = .{ .path = field_path };
            i += 1;
            i = appendAllocSites(
                @typeInfo(field.type).pointer.child,
                field_path,
                out,
                i,
            );
        }
    }
    return i;
}

fn FieldPlan(comptime T: type) type {
    const n_leaves = leafCount(T);
    const n_allocs = allocSiteCount(T);

    const leaf_buffer = blk: {
        var buf: [n_leaves]LeafDesc = undefined;
        _ = appendLeaves(T, &.{}, "", &buf, 0);
        break :blk buf;
    };

    const alloc_buffer = blk: {
        var buf: [n_allocs]AllocDesc = undefined;
        _ = appendAllocSites(T, &.{}, &buf, 0);
        break :blk buf;
    };

    return struct {
        pub const leaves: [n_leaves]LeafDesc = leaf_buffer;
        pub const allocs: [n_allocs]AllocDesc = alloc_buffer;
    };
}

pub const ParseError = error{
    MissingRequiredField,
    TypeConversionError,
    InvalidContainer,
};

fn ParentTypeAt(comptime T: type, comptime path: []const []const u8) type {
    if (path.len == 0) return T;
    const FT = fieldTypeByName(T, path[0]);
    if (!isNestedStructPtr(FT)) @compileError("alloc path must be a nested struct");
    return ParentTypeAt(@typeInfo(FT).pointer.child, path[1..]);
}

fn LeafTypeAt(comptime T: type, comptime path: []const []const u8) type {
    const FT = fieldTypeByName(T, path[0]);
    if (path.len == 1) return FT;
    if (!isNestedStructPtr(FT)) @compileError("path walks through non-nested field");
    return LeafTypeAt(@typeInfo(FT).pointer.child, path[1..]);
}

inline fn nestedPtr(comptime T: type, root: *T, comptime path: []const []const u8) *ParentTypeAt(T, path) {
    if (comptime path.len == 0) return root;
    const child_ptr = @field(root.*, path[0]);
    const Child = @typeInfo(@TypeOf(child_ptr)).pointer.child;
    return nestedPtr(Child, child_ptr, path[1..]);
}

inline fn leafPtr(comptime T: type, root: *T, comptime path: []const []const u8) *LeafTypeAt(T, path) {
    if (comptime path.len == 1) {
        return &@field(root.*, path[0]);
    }
    const child_ptr = @field(root.*, path[0]);
    const Child = @typeInfo(@TypeOf(child_ptr)).pointer.child;
    return leafPtr(Child, child_ptr, path[1..]);
}

fn convertScalar(comptime T: type, allocator: zstd.mem.Allocator, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => zstd.fmt.parseInt(T, value, 10) catch ParseError.TypeConversionError,
        .float => zstd.fmt.parseFloat(T, value) catch ParseError.TypeConversionError,
        .bool => blk: {
            const lower = zstd.ascii.allocLowerString(allocator, value) catch {
                return ParseError.TypeConversionError;
            };
            defer allocator.free(lower);
            if (zstd.mem.eql(u8, lower, "true") or zstd.mem.eql(u8, lower, "1")) {
                break :blk true;
            }
            if (zstd.mem.eql(u8, lower, "false") or zstd.mem.eql(u8, lower, "0")) {
                break :blk false;
            }
            return ParseError.TypeConversionError;
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try allocator.dupe(u8, value);
            }
            return ParseError.TypeConversionError;
        },
        else => ParseError.TypeConversionError,
    };
}

fn convertValue(comptime FieldType: type, allocator: zstd.mem.Allocator, value: []const u8) !FieldType {
    comptime var T = FieldType;
    comptime var optional_depth: usize = 0;
    inline while (@typeInfo(T) == .optional) {
        optional_depth += 1;
        T = @typeInfo(T).optional.child;
    }

    if (optional_depth > 0 and value.len == 0) {
        return null;
    }

    const scalar = try convertScalar(T, allocator, value);

    if (comptime optional_depth == 0) {
        return scalar;
    } else if (comptime optional_depth == 1) {
        return @as(FieldType, scalar);
    } else {
        @compileError("nested optionals deeper than 1 are not supported");
    }
}

fn duplicateScalar(comptime T: type, allocator: zstd.mem.Allocator, value: T) !T {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                break :blk try allocator.dupe(u8, value);
            }
            break :blk value;
        },
        else => value,
    };
}

fn duplicateIfNeeded(comptime FieldType: type, allocator: zstd.mem.Allocator, value: FieldType) !FieldType {
    if (@typeInfo(FieldType) == .optional) {
        if (value) |inner| {
            return try duplicateScalar(@TypeOf(inner), allocator, inner);
        }
        return null;
    }
    return try duplicateScalar(FieldType, allocator, value);
}

fn defaultForLeaf(comptime T: type, comptime path: []const []const u8) ?*const LeafTypeAt(T, path) {
    if (comptime path.len != 1) {
        const Parent = ParentTypeAt(T, path[0 .. path.len - 1]);
        const field = fieldInfoByName(Parent, path[path.len - 1]);
        if (field.default_value_ptr) |ptr| {
            return @as(*const LeafTypeAt(T, path), @ptrCast(@alignCast(ptr)));
        }
        return null;
    }
    const field = fieldInfoByName(T, path[0]);
    if (field.default_value_ptr) |ptr| {
        return @as(*const LeafTypeAt(T, path), @ptrCast(@alignCast(ptr)));
    }
    return null;
}

fn freeScalar(comptime T: type, allocator: zstd.mem.Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                allocator.free(value);
            }
        },
        else => {},
    }
}

fn freeLeaf(comptime FieldType: type, allocator: zstd.mem.Allocator, value: FieldType) void {
    if (@typeInfo(FieldType) == .optional) {
        if (value) |inner| {
            freeScalar(@TypeOf(inner), allocator, inner);
        }
        return;
    }
    freeScalar(FieldType, allocator, value);
}

pub fn parse(
    comptime T: type,
    allocator: zstd.mem.Allocator,
    prefix: ?[]const u8,
    env: zstd.process.Environ.Map,
) !*T {
    if (@typeInfo(T) != .@"struct")
        return ParseError.InvalidContainer;

    const Plan = FieldPlan(T);
    const container = try allocator.create(T);

    var nested_allocated: usize = 0;
    var leaves_initialized: usize = 0;
    errdefer freePartial(
        T,
        allocator,
        container,
        nested_allocated,
        leaves_initialized,
    );

    inline for (Plan.allocs) |site| {
        const parent = nestedPtr(T, container, site.path[0 .. site.path.len - 1]);
        const field_name = site.path[site.path.len - 1];
        const Child = ParentTypeAt(T, site.path);
        @field(parent.*, field_name) = try allocator.create(Child);
        nested_allocated += 1;
    }

    inline for (Plan.leaves, 0..) |leaf, leaf_idx| {
        const FieldType = LeafTypeAt(T, leaf.path);
        const env_key = try makePrefixedKey(allocator, prefix, leaf.key);
        defer allocator.free(env_key);

        var uppercase_key = try allocator.alloc(u8, env_key.len);
        defer allocator.free(uppercase_key);

        uppercase_key = zstd.ascii.upperString(uppercase_key, env_key);
        const key: []const u8 = uppercase_key[0..env_key.len];

        const dest = leafPtr(T, container, leaf.path);

        if (env.get(key)) |val| {
            dest.* = try convertValue(FieldType, allocator, val);
        } else if (comptime defaultForLeaf(T, leaf.path)) |default_ptr| {
            dest.* = try duplicateIfNeeded(FieldType, allocator, default_ptr.*);
        } else if (comptime isOptionalLeaf(FieldType)) {
            dest.* = null;
        } else {
            return ParseError.MissingRequiredField;
        }

        leaves_initialized = leaf_idx + 1;
    }

    return container;
}

fn freePartial(
    comptime T: type,
    allocator: zstd.mem.Allocator,
    container: *T,
    nested_allocated: usize,
    leaves_initialized: usize,
) void {
    const Plan = FieldPlan(T);

    inline for (Plan.leaves, 0..) |leaf, i| {
        if (i < leaves_initialized) {
            freeLeaf(LeafTypeAt(T, leaf.path), allocator, leafPtr(T, container, leaf.path).*);
        }
    }

    comptime var a = Plan.allocs.len;
    inline while (a > 0) {
        a -= 1;
        if (a < nested_allocated) {
            const site = Plan.allocs[a];
            const parent = nestedPtr(T, container, site.path[0 .. site.path.len - 1]);
            allocator.destroy(@field(parent.*, site.path[site.path.len - 1]));
        }
    }

    allocator.destroy(container);
}

fn free(comptime T: type, allocator: zstd.mem.Allocator, container: *T) void {
    const Plan = FieldPlan(T);

    inline for (Plan.leaves) |leaf| {
        freeLeaf(LeafTypeAt(T, leaf.path), allocator, leafPtr(T, container, leaf.path).*);
    }

    comptime var a = Plan.allocs.len;
    inline while (a > 0) {
        a -= 1;
        const site = Plan.allocs[a];
        const parent_path = site.path[0 .. site.path.len - 1];
        const field_name = site.path[site.path.len - 1];
        const parent = nestedPtr(T, container, parent_path);
        const child_ptr = @field(parent.*, field_name);
        allocator.destroy(child_ptr);
    }

    allocator.destroy(container);
}

pub fn deinit(comptime T: type, allocator: zstd.mem.Allocator, container: *T) void {
    free(T, allocator, container);
}
