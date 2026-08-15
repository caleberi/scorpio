const zstd = @import("std");

pub const ValidationError = error{
    ValidatorNotFound,
    ValidationFailed,
    InvalidParameterCount,
    InvalidParameterType,
    NoSpaceLeft,
};

pub const Context = struct {
    field_name: []const u8,
    value: Value,
    params: []const Parameter,
    allocator: zstd.mem.Allocator,
};

pub const Parameter = struct {
    key: ?[]const u8,
    value: []const u8,
};

pub const Validator = struct {
    name: []const u8,
    params: []const Parameter,
};

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

pub const ValidationReturnType = ValidationError!ValidationResult;
pub const ValidatorFn = *const fn (ctx: Context) ValidationReturnType;

pub const ValidationMessage = struct {
    name: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8,

    pub fn success() ValidationResult {
        return .{
            .valid = true,
            .error_message = null,
        };
    }

    pub fn failure(message: []const u8) ValidationResult {
        return .{
            .valid = false,
            .error_message = message,
        };
    }
};

pub const Engine = struct {
    allocator: zstd.mem.Allocator,
    validators: zstd.StringHashMap(ValidatorFn),
    default_messages: zstd.StringHashMap([]const u8),

    pub fn init(allocator: zstd.mem.Allocator) !Engine {
        return .{
            .allocator = allocator,
            .validators = zstd.StringHashMap(ValidatorFn).init(allocator),
            .default_messages = zstd.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Engine) void {
        var validator_iter = self.validators.iterator();
        while (validator_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.validators.deinit();

        var msg_iter = self.default_messages.iterator();
        while (msg_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.default_messages.deinit();
    }

    pub fn registerValidator(
        self: *Engine,
        name: []const u8,
        validator_fn: ValidatorFn,
    ) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.validators.put(key, validator_fn);
    }

    pub fn registerDefaultMessage(
        self: *Engine,
        validator_name: []const u8,
        message: []const u8,
    ) !void {
        const key = try self.allocator.dupe(u8, validator_name);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(value);
        try self.default_messages.put(key, value);
    }

    pub fn validate(
        self: *Engine,
        field_name: []const u8,
        value: Value,
        validator_name: []const u8,
        params: []const Parameter,
    ) !ValidationResult {
        const validator_fn = self.validators.get(validator_name) orelse {
            return ValidationError.ValidatorNotFound;
        };

        const ctx = Context{
            .field_name = field_name,
            .value = value,
            .params = params,
            .allocator = self.allocator,
        };

        return try validator_fn(ctx);
    }

    pub fn validateField(
        self: *Engine,
        field_name: []const u8,
        value: Value,
        validators: []const Validator,
        messages: []const ValidationMessage,
    ) ![]ValidationResult {
        var results = try zstd.ArrayList(ValidationResult).initCapacity(
            self.allocator,
            validators.len,
        );
        errdefer results.deinit(self.allocator);

        for (validators) |validator| {
            const result = try self.validate(
                field_name,
                value,
                validator.name,
                validator.params,
            );

            if (!result.valid) {
                var custom_message: ?[]const u8 = null;
                for (messages) |msg| {
                    if (zstd.mem.eql(u8, msg.name, validator.name)) {
                        custom_message = msg.message;
                        break;
                    }
                }

                if (custom_message) |msg| {
                    try results.append(
                        self.allocator,
                        ValidationResult.failure(msg),
                    );
                } else {
                    try results.append(self.allocator, result);
                }
            } else {
                try results.append(self.allocator, result);
            }
        }

        return results.toOwnedSlice(self.allocator);
    }
};

const validator_funcs = @import("default.zig");

test "validator registration and execution" {
    const allocator = zstd.testing.allocator;

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    try engine.registerValidator("alpha", validator_funcs.alphaValidator);
    try engine.registerValidator("numeric", validator_funcs.numericValidator);
    try engine.registerValidator("min_length", validator_funcs.minLengthValidator);
    try engine.registerValidator("max_length", validator_funcs.maxLengthValidator);
    try engine.registerValidator("min", validator_funcs.minValidator);
    try engine.registerValidator("max", validator_funcs.maxValidator);
    try engine.registerValidator("required", validator_funcs.requiredValidator);

    const Spec = struct {
        field_name: []const u8,
        value: Value,
        validator_func: []const u8,
        params: []const Parameter,
        expect_valid: bool,
    };

    const testcases: []const Spec = &.{
        .{
            .field_name = "name",
            .value = .{ .string = "JohnDoe" },
            .validator_func = "alpha",
            .params = &.{},
            .expect_valid = true,
        },
        .{
            .field_name = "age",
            .value = .{ .int = 25 },
            .validator_func = "numeric",
            .params = &.{},
            .expect_valid = true,
        },
        .{
            .field_name = "age",
            .value = .{ .string = "25" },
            .validator_func = "numeric",
            .params = &.{},
            .expect_valid = true,
        },
        .{
            .field_name = "name",
            .value = .{ .string = "John" },
            .validator_func = "min_length",
            .params = &[_]Parameter{.{
                .key = null,
                .value = "5",
            }},
            .expect_valid = false,
        },
        .{
            .field_name = "name",
            .value = .{ .string = "JohnDoe" },
            .validator_func = "max_length",
            .params = &[_]Parameter{.{
                .key = null,
                .value = "10",
            }},
            .expect_valid = true,
        },
        .{
            .field_name = "age",
            .value = .{ .int = 25 },
            .validator_func = "min",
            .params = &[_]Parameter{.{
                .key = null,
                .value = "18",
            }},
            .expect_valid = true,
        },
        .{
            .field_name = "age",
            .value = .{ .int = 150 },
            .validator_func = "max",
            .params = &[_]Parameter{.{
                .key = null,
                .value = "100",
            }},
            .expect_valid = false,
        },
        .{
            .field_name = "field",
            .value = .{ .string = "" },
            .validator_func = "required",
            .params = &.{},
            .expect_valid = false,
        },
        .{
            .field_name = "port",
            .value = .{ .int = 8080 },
            .validator_func = "required",
            .params = &.{},
            .expect_valid = true,
        },
    };

    for (testcases) |tc| {
        const result = try engine.validate(tc.field_name, tc.value, tc.validator_func, tc.params);
        try zstd.testing.expectEqual(tc.expect_valid, result.valid);
    }
}

test "custom validator registration" {
    const allocator = zstd.testing.allocator;

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const customValidator = struct {
        fn validator(ctx: Context) ValidationReturnType {
            const s = ctx.value.asString() orelse {
                return ValidationResult.failure("Must be a string");
            };
            if (zstd.mem.eql(u8, s, "special")) {
                return ValidationResult.success();
            }
            return ValidationResult.failure("Must be 'special'");
        }
    }.validator;

    try engine.registerValidator("custom", customValidator);
    try zstd.testing.expect((try engine.validate("field", .{ .string = "special" }, "custom", &.{})).valid);
    try zstd.testing.expect(!(try engine.validate("field", .{ .string = "other" }, "custom", &.{})).valid);
}

test "typed custom validator without string formatting" {
    const allocator = zstd.testing.allocator;
    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const evenValidator = struct {
        fn validator(ctx: Context) ValidationReturnType {
            const n = ctx.value.asInt() orelse {
                return ValidationResult.failure("Must be an integer");
            };
            if (@rem(n, 2) == 0) return ValidationResult.success();
            return ValidationResult.failure("Must be even");
        }
    }.validator;

    const oddValidator = struct {
        fn validator(ctx: Context) ValidationReturnType {
            const n = ctx.value.asInt() orelse {
                return ValidationResult.failure("Must be an integer");
            };
            if (@rem(n, 2) != 0) return ValidationResult.success();
            return ValidationResult.failure("Must be even");
        }
    }.validator;

    try engine.registerValidator("even", evenValidator);
    try engine.registerValidator("odd", oddValidator);

    try zstd.testing.expect((try engine.validate("n", .{ .int = 4 }, "even", &.{})).valid);
    try zstd.testing.expect(!(try engine.validate("n", .{ .int = 3 }, "even", &.{})).valid);
    try zstd.testing.expect(!(try engine.validate("n", .{ .int = 4 }, "odd", &.{})).valid);
    try zstd.testing.expect((try engine.validate("n", .{ .int = 3 }, "odd", &.{})).valid);
}

test "validate field with multiple validators" {
    const allocator = zstd.testing.allocator;

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    try engine.registerValidator("alpha", validator_funcs.alphaValidator);
    try engine.registerValidator("min_length", validator_funcs.minLengthValidator);
    try engine.registerValidator("max_length", validator_funcs.maxLengthValidator);

    var validators = try zstd.ArrayList(Validator).initCapacity(allocator, 0);
    defer validators.deinit(allocator);

    try validators.append(allocator, .{ .name = "alpha", .params = &.{} });
    try validators.append(allocator, .{ .name = "min_length", .params = &[_]Parameter{.{ .key = null, .value = "3" }} });
    try validators.append(allocator, .{ .name = "max_length", .params = &[_]Parameter{.{ .key = null, .value = "50" }} });

    var messages = try zstd.ArrayList(ValidationMessage).initCapacity(allocator, 0);
    defer messages.deinit(allocator);

    try messages.append(allocator, .{ .name = "alpha", .message = "Name must be alphabetic only" });
    try messages.append(allocator, .{ .name = "min_length", .message = "Name must be at least 3 characters" });
    try messages.append(allocator, .{ .name = "max_length", .message = "Name cannot exceed 50 characters" });

    const validators_slice = try validators.toOwnedSlice(allocator);
    defer allocator.free(validators_slice);

    const messages_slice = try messages.toOwnedSlice(allocator);
    defer allocator.free(messages_slice);

    const results = try engine.validateField(
        "name",
        .{ .string = "John" },
        validators_slice,
        messages_slice,
    );
    defer allocator.free(results);

    try zstd.testing.expect(results.len == 3);
    try zstd.testing.expect(results[0].valid);
    try zstd.testing.expect(results[1].valid);
    try zstd.testing.expect(results[2].valid);
}
