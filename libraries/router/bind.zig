const std = @import("std");
const zap = @import("zap");
const match = @import("match.zig");

pub const BindError = error{
    MissingField,
    InvalidValue,
    OutOfMemory,
};

fn isJsonBody(body: []const u8) bool {
    return body.len > 0 and body[0] == '{';
}

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    method: match.Method,
    path: []const u8,
    /// Flattened path + query + body params. Values owned by this context.
    values: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn deinit(self: *RequestContext) void {
        var it = self.values.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn put(self: *RequestContext, key: []const u8, value: []const u8) !void {
        const key_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_owned);

        const value_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_owned);

        const gop = try self.values.getOrPut(
            self.allocator,
            key_owned,
        );
        if (gop.found_existing) {
            self.allocator.free(key_owned);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = value_owned;
        } else {
            gop.key_ptr.* = key_owned;
            gop.value_ptr.* = value_owned;
        }
    }

    pub fn get(self: *const RequestContext, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }

    /// Build a context from a Zap request. `path_params` values are copied in.
    pub fn fromZap(
        allocator: std.mem.Allocator,
        request: zap.Request,
        path_params: *const match.PathParams,
    ) !RequestContext {
        var ctx = RequestContext{
            .allocator = allocator,
            .method = match.methodFromRequest(request.method),
            .path = request.path orelse "/",
        };
        errdefer ctx.deinit();

        var path_it = path_params.iterator();
        while (path_it.next()) |entry| {
            const text = try entry.value_ptr.toString(allocator);
            defer allocator.free(text);
            try ctx.put(entry.key_ptr.*, text);
        }

        request.parseBody() catch {};
        request.parseQuery();

        var slices = request.getParamSlices();
        while (slices.next()) |kv| {
            try ctx.put(kv.name, kv.value);
        }

        if (request.body) |body| {
            if (isJsonBody(body)) try mergeJsonObject(&ctx, body);
        }

        return ctx;
    }
};

fn mergeJsonObject(ctx: *RequestContext, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        ctx.allocator,
        body,
        .{},
    ) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const as_text = jsonValueToString(ctx.allocator, entry.value_ptr.*) catch continue;
        defer ctx.allocator.free(as_text);
        try ctx.put(entry.key_ptr.*, as_text);
    }
}

fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .null => try allocator.dupe(u8, ""),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| try allocator.dupe(u8, s),
        .string => |s| try allocator.dupe(u8, s),
        else => error.InvalidValue,
    };
}

/// Bind flattened string params into an `Inputs` struct.
pub fn bind(comptime Inputs: type, ctx: *const RequestContext) BindError!Inputs {
    var result: Inputs = undefined;

    inline for (@typeInfo(Inputs).@"struct".fields) |field| {
        const raw = ctx.get(field.name);
        const FieldType = field.type;
        const is_optional = @typeInfo(FieldType) == .optional;

        if (raw) |text| {
            if (comptime is_optional) {
                const Child = @typeInfo(FieldType).optional.child;
                @field(result, field.name) = try coerce(Child, text);
            } else {
                @field(result, field.name) = try coerce(FieldType, text);
            }
        } else if (comptime is_optional) {
            @field(result, field.name) = null;
        } else if (comptime field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

fn coerce(comptime T: type, text: []const u8) BindError!T {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| blk: {
            if (ptr.size != .slice or ptr.child != u8) {
                @compileError("Unsupported input pointer type: " ++ @typeName(T));
            }
            break :blk text;
        },
        .int => std.fmt.parseInt(T, text, 10) catch return error.InvalidValue,
        .bool => blk: {
            if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) break :blk true;
            if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) break :blk false;
            return error.InvalidValue;
        },
        .float => std.fmt.parseFloat(T, text) catch return error.InvalidValue,
        else => @compileError("Unsupported input field type: " ++ @typeName(T)),
    };
}

const testing = std.testing;

test "bind required and optional fields" {
    var ctx = RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();
    try ctx.put("name", "ada");
    try ctx.put("active", "true");

    const Inputs = struct {
        name: []const u8,
        active: bool,
        nickname: ?[]const u8 = null,
    };

    const inputs = try bind(Inputs, &ctx);
    try testing.expectEqualStrings("ada", inputs.name);
    try testing.expect(inputs.active);
    try testing.expect(inputs.nickname == null);
}

test "bind missing required field" {
    var ctx = RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();

    const Inputs = struct { name: []const u8 };
    try testing.expectError(
        error.MissingField,
        bind(Inputs, &ctx),
    );
}
