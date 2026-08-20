const zstd = @import("std");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
pub const engine = @import("engine.zig");
const validator = @import("default.zig");

pub const SchemaError = error{
    MissingDocumentation,
    InvalidContainer,
    TooManyParameters,
    OutOfMemory,
    ValidatorNotFound,
    InvalidParameterCount,
    InvalidParameterType,
    NoSpaceLeft,
    UnexpectedEOF,
    UnexpectedToken,
    InvalidToken,
};

pub const FieldError = struct {
    path: []const u8,
    rule: []const u8,
    message: []const u8,

    pub fn deinit(self: FieldError, allocator: zstd.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Outcome = union(enum) {
    ok,
    err: FieldError,

    pub fn deinit(self: Outcome, allocator: zstd.mem.Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| e.deinit(allocator),
        }
    }
};

pub fn docOf(comptime S: type) []const u8 {
    if (@hasDecl(S, "doc")) return @field(S, "doc");
    if (@hasDecl(S, "documentation")) return @field(S, "documentation");
    return "";
}

fn isDocField(comptime name: []const u8) bool {
    return zstd.mem.eql(u8, name, "doc") or zstd.mem.eql(u8, name, "documentation");
}

fn nestedStructType(comptime FieldType: type) ?type {
    return switch (@typeInfo(FieldType)) {
        .@"struct" => FieldType,
        .pointer => |ptr| if (ptr.size == .one and @typeInfo(ptr.child) == .@"struct")
            ptr.child
        else
            null,
        .optional => |opt| nestedStructType(opt.child),
        else => null,
    };
}

fn unwrapNested(value: anytype) nestedStructType(@TypeOf(value)).? {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => value,
        .pointer => value.*,
        .optional => unwrapNested(value.?),
        else => @compileError("unwrapNested expects struct, *struct, or optional thereof"),
    };
}

fn joinPath(allocator: zstd.mem.Allocator, prefix: []const u8, name: []const u8) SchemaError![]u8 {
    if (prefix.len == 0) {
        return allocator.dupe(u8, name) catch return error.OutOfMemory;
    }
    return zstd.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, name }) catch return error.OutOfMemory;
}

pub fn DefaultEngine(allocator: zstd.mem.Allocator) SchemaError!engine.Engine {
    var e = engine.Engine.init(allocator) catch return error.OutOfMemory;
    errdefer e.deinit();

    e.registerValidator("alpha", validator.alphaValidator) catch return error.OutOfMemory;
    e.registerValidator("numeric", validator.numericValidator) catch return error.OutOfMemory;
    e.registerValidator("min_length", validator.minLengthValidator) catch return error.OutOfMemory;
    e.registerValidator("max_length", validator.maxLengthValidator) catch return error.OutOfMemory;
    e.registerValidator("min", validator.minValidator) catch return error.OutOfMemory;
    e.registerValidator("max", validator.maxValidator) catch return error.OutOfMemory;
    e.registerValidator("required", validator.requiredValidator) catch return error.OutOfMemory;
    e.registerValidator("email", validator.emailValidator) catch return error.OutOfMemory;

    e.registerDefaultMessage("alpha", "Field must contain only alphabetic characters") catch return error.OutOfMemory;
    e.registerDefaultMessage("numeric", "Field must be numeric") catch return error.OutOfMemory;
    e.registerDefaultMessage("min_length", "Field length is below minimum") catch return error.OutOfMemory;
    e.registerDefaultMessage("max_length", "Field length exceeds maximum") catch return error.OutOfMemory;
    e.registerDefaultMessage("min", "Value is below minimum") catch return error.OutOfMemory;
    e.registerDefaultMessage("max", "Value exceeds maximum") catch return error.OutOfMemory;
    e.registerDefaultMessage("required", "Field is required") catch return error.OutOfMemory;
    e.registerDefaultMessage("email", "Invalid email format") catch return error.OutOfMemory;

    return e;
}

pub fn register(
    e: *engine.Engine,
    name: []const u8,
    validator_fn: engine.ValidatorFn,
) SchemaError!void {
    e.registerValidator(name, validator_fn) catch return error.OutOfMemory;
}

pub const default_validator_names = [_][]const u8{
    "alpha",
    "numeric",
    "min_length",
    "max_length",
    "min",
    "max",
    "required",
    "email",
};

pub fn isDefaultValidator(name: []const u8) bool {
    for (default_validator_names) |n| {
        if (zstd.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn isAllowedValidator(name: []const u8, extra: []const []const u8) bool {
    if (isDefaultValidator(name)) return true;
    for (extra) |n| {
        if (zstd.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const ScanState = struct {
    i: usize = 0,
    in_list: bool = false,
};

fn isIdentContinue(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn skipWs(source: []const u8, state: *ScanState) void {
    while (state.i < source.len) {
        switch (source[state.i]) {
            ' ', '\t' => state.i += 1,
            else => return,
        }
    }
}

fn nextValidatorName(source: []const u8, state: *ScanState) ?[]const u8 {
    const marker = "@validator:";
    while (state.i < source.len) {
        if (!state.in_list) {
            if (state.i + marker.len <= source.len and
                zstd.mem.eql(u8, source[state.i .. state.i + marker.len], marker))
            {
                state.i += marker.len;
                state.in_list = true;
                continue;
            }
            state.i += 1;
            continue;
        }

        skipWs(source, state);
        if (state.i >= source.len) return null;
        switch (source[state.i]) {
            '\n', '\r' => {
                state.in_list = false;
                state.i += 1;
                continue;
            },
            ',' => {
                state.i += 1;
                continue;
            },
            else => {},
        }

        if (source[state.i] == '@') state.i += 1;
        const start = state.i;
        while (state.i < source.len and isIdentContinue(source[state.i])) state.i += 1;
        if (state.i == start) {
            while (state.i < source.len and source[state.i] != ',' and source[state.i] != '\n' and source[state.i] != '\r') {
                state.i += 1;
            }
            continue;
        }
        const name = source[start..state.i];
        while (state.i < source.len and source[state.i] != ',' and source[state.i] != '\n' and source[state.i] != '\r') {
            state.i += 1;
        }
        return name;
    }
    return null;
}

fn countValidatorNames(source: []const u8) usize {
    var state: ScanState = .{};
    var count: usize = 0;
    while (nextValidatorName(source, &state)) |_| count += 1;
    return count;
}

pub fn scanValidatorNames(comptime source: []const u8) []const []const u8 {
    const names = comptime blk: {
        const count = countValidatorNames(source);
        var result: [count][]const u8 = undefined;
        var state: ScanState = .{};
        for (&result) |*slot| {
            slot.* = nextValidatorName(source, &state).?;
        }
        break :blk result;
    };
    return &names;
}

pub fn assertKnownValidators(comptime T: type, comptime extra: []const []const u8) void {
    const source = docOf(T);
    comptime {
        var state: ScanState = .{};
        while (nextValidatorName(source, &state)) |name| {
            if (!isAllowedValidator(name, extra)) {
                @compileError("unregistered validator '" ++ name ++ "' in " ++ @typeName(T));
            }
        }
    }

    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".fields) |field| {
        if (comptime !isDocField(field.name)) {
            if (comptime nestedStructType(field.type)) |Child| {
                assertKnownValidators(Child, extra);
            }
        }
    }
}

pub const CompiledDoc = struct {
    allocator: zstd.mem.Allocator,
    documentation: lexer.Documentation,

    by_name: zstd.StringHashMap(usize),

    pub fn compile(allocator: zstd.mem.Allocator, source: []const u8) SchemaError!CompiledDoc {
        if (source.len == 0) {
            return .{
                .allocator = allocator,
                .documentation = .{ .specs = &.{} },
                .by_name = zstd.StringHashMap(usize).init(allocator),
            };
        }

        var lex = lexer.Lexer.init(allocator, source) catch return error.OutOfMemory;
        defer lex.deinit();

        const tokens = lex.lex() catch return error.OutOfMemory;
        var p = parser.Parser.init(allocator, tokens, source);
        const documentation = p.parse() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnexpectedEOF => return error.UnexpectedEOF,
            error.UnexpectedToken => return error.UnexpectedToken,
            error.InvalidToken => return error.InvalidToken,
            else => return error.UnexpectedToken,
        };
        errdefer documentation.deinit(allocator);

        var by_name = zstd.StringHashMap(usize).init(allocator);
        errdefer by_name.deinit();

        for (documentation.specs, 0..) |spec, i| {
            by_name.put(spec.property, i) catch return error.OutOfMemory;
        }

        return .{
            .allocator = allocator,
            .documentation = documentation,
            .by_name = by_name,
        };
    }

    pub fn deinit(self: *CompiledDoc) void {
        if (self.documentation.specs.len > 0) {
            self.documentation.deinit(self.allocator);
        }
        self.by_name.deinit();
    }

    pub fn getSpecFor(self: *const CompiledDoc, field_name: []const u8) ?*const lexer.Specification {
        const idx = self.by_name.get(field_name) orelse return null;
        return &self.documentation.specs[idx];
    }
};

pub fn Schema(comptime T: type) type {
    return struct {
        compiled: CompiledDoc,
        allocator: zstd.mem.Allocator,
        nested: zstd.StringHashMap(CompiledDoc),

        const Self = @This();

        pub fn compile(allocator: zstd.mem.Allocator, source: ?[]const u8) SchemaError!Self {
            const doc_source = if (source) |s| s else docOf(T);

            var compiled = try CompiledDoc.compile(allocator, doc_source);
            errdefer compiled.deinit();

            var nested = zstd.StringHashMap(CompiledDoc).init(allocator);
            errdefer {
                var it = nested.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.deinit();
                }
                nested.deinit();
            }

            const info = @typeInfo(T);
            if (info != .@"struct") return error.InvalidContainer;

            inline for (info.@"struct".fields) |field| {
                if (comptime !isDocField(field.name)) {
                    if (comptime nestedStructType(field.type)) |Child| {
                        const nested_source = docOf(Child);
                        if (nested_source.len > 0) {
                            var nested_compiled = try CompiledDoc.compile(allocator, nested_source);
                            errdefer nested_compiled.deinit();
                            nested.put(field.name, nested_compiled) catch return error.OutOfMemory;
                        }
                    }
                }
            }

            return .{
                .allocator = allocator,
                .compiled = compiled,
                .nested = nested,
            };
        }

        pub fn deinit(self: *Self) void {
            self.compiled.deinit();
            var it = self.nested.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.nested.deinit();
        }

        pub fn validate(self: *Self, eng: *engine.Engine, value: T) SchemaError!Outcome {
            return self.validateAt(eng, value, "");
        }

        pub fn ensureRegistered(self: *const Self, eng: *const engine.Engine) SchemaError!void {
            try ensureCompiledRegistered(&self.compiled, eng);
            var it = self.nested.iterator();
            while (it.next()) |entry| {
                try ensureCompiledRegistered(entry.value_ptr, eng);
            }
        }

        fn validateAt(
            self: *Self,
            eng: *engine.Engine,
            value: anytype,
            path_prefix: []const u8,
        ) SchemaError!Outcome {
            const V = @TypeOf(value);
            const info = @typeInfo(V);
            if (info != .@"struct") return error.InvalidContainer;

            inline for (info.@"struct".fields) |field| {
                if (comptime !isDocField(field.name)) {
                    const field_value = @field(value, field.name);

                    if (comptime nestedStructType(field.type) != null) {
                        if (self.nested.getPtr(field.name)) |nested_doc| {
                            if (comptime @typeInfo(field.type) == .optional) {
                                if (field_value) |inner| {
                                    const child_path = try joinPath(self.allocator, path_prefix, field.name);
                                    defer self.allocator.free(child_path);
                                    const outcome = try validateNested(
                                        self.allocator,
                                        eng,
                                        unwrapNested(inner),
                                        child_path,
                                        nested_doc,
                                        &self.nested,
                                    );
                                    if (outcome == .err) return outcome;
                                }
                            } else {
                                const child_path = try joinPath(self.allocator, path_prefix, field.name);
                                defer self.allocator.free(child_path);
                                const outcome = try validateNested(
                                    self.allocator,
                                    eng,
                                    unwrapNested(field_value),
                                    child_path,
                                    nested_doc,
                                    &self.nested,
                                );
                                if (outcome == .err) return outcome;
                            }
                        }
                    } else if (self.compiled.getSpecFor(field.name)) |spec| {
                        const outcome = try validateLeaf(
                            self.allocator,
                            eng,
                            path_prefix,
                            field.name,
                            field_value,
                            spec,
                        );
                        if (outcome == .err) return outcome;
                    }
                }
            }
            return .ok;
        }
    };
}

fn ensureCompiledRegistered(compiled: *const CompiledDoc, eng: *const engine.Engine) SchemaError!void {
    for (compiled.documentation.specs) |spec| {
        for (spec.validators) |rule| {
            if (eng.validators.get(rule.name) == null) return error.ValidatorNotFound;
        }
    }
}

fn validateNested(
    allocator: zstd.mem.Allocator,
    eng: *engine.Engine,
    value: anytype,
    path_prefix: []const u8,
    compiled: *CompiledDoc,
    nested_cache: *zstd.StringHashMap(CompiledDoc),
) SchemaError!Outcome {
    const V = @TypeOf(value);
    const info = @typeInfo(V);
    if (info != .@"struct") return error.InvalidContainer;

    inline for (info.@"struct".fields) |field| {
        if (comptime !isDocField(field.name)) {
            const field_value = @field(value, field.name);

            if (comptime nestedStructType(field.type)) |Child| {
                const nested_source = docOf(Child);
                if (nested_source.len > 0) {
                    const gop = nested_cache.getOrPut(field.name) catch return error.OutOfMemory;
                    if (!gop.found_existing) {
                        gop.value_ptr.* = try CompiledDoc.compile(allocator, nested_source);
                    }

                    if (comptime @typeInfo(field.type) == .optional) {
                        if (field_value) |inner| {
                            const child_path = try joinPath(allocator, path_prefix, field.name);
                            defer allocator.free(child_path);
                            const outcome = try validateNested(
                                allocator,
                                eng,
                                unwrapNested(inner),
                                child_path,
                                gop.value_ptr,
                                nested_cache,
                            );
                            if (outcome == .err) return outcome;
                        }
                    } else {
                        const child_path = try joinPath(allocator, path_prefix, field.name);
                        defer allocator.free(child_path);
                        const outcome = try validateNested(
                            allocator,
                            eng,
                            unwrapNested(field_value),
                            child_path,
                            gop.value_ptr,
                            nested_cache,
                        );
                        if (outcome == .err) return outcome;
                    }
                }
            } else if (compiled.getSpecFor(field.name)) |spec| {
                const outcome = try validateLeaf(
                    allocator,
                    eng,
                    path_prefix,
                    field.name,
                    field_value,
                    spec,
                );
                if (outcome == .err) return outcome;
            }
        }
    }
    return .ok;
}

fn validateLeaf(
    allocator: zstd.mem.Allocator,
    eng: *engine.Engine,
    path_prefix: []const u8,
    field_name: []const u8,
    field_value: anytype,
    spec: *const lexer.Specification,
) SchemaError!Outcome {
    var value_buf: [256]u8 = undefined;
    const value = try toValue(&value_buf, field_value);

    for (spec.validators) |rule| {
        if (value == .int) {
            if (zstd.mem.eql(u8, rule.name, "numeric")) continue;
            if (zstd.mem.eql(u8, rule.name, "min") or zstd.mem.eql(u8, rule.name, "max")) {
                if (try checkIntRange(value.int, rule)) |fail_msg| {
                    return fail(allocator, path_prefix, field_name, rule.name, messageFor(spec, rule.name, fail_msg));
                }
                continue;
            }
        }

        var params_buf: [32]engine.Parameter = undefined;
        if (rule.params.len > params_buf.len) return error.TooManyParameters;
        for (rule.params, 0..) |param, i| {
            params_buf[i] = .{
                .key = param.key,
                .value = param.value,
            };
        }

        const result = eng.validate(
            field_name,
            value,
            rule.name,
            params_buf[0..rule.params.len],
        ) catch |err| switch (err) {
            error.ValidatorNotFound => return error.ValidatorNotFound,
            error.InvalidParameterCount => return error.InvalidParameterCount,
            error.InvalidParameterType => return error.InvalidParameterType,
            error.NoSpaceLeft => return error.NoSpaceLeft,
            error.ValidationFailed => return error.ValidatorNotFound,
        };

        if (!result.valid) {
            const msg = messageFor(spec, rule.name, result.error_message orelse "validation failed");
            return fail(allocator, path_prefix, field_name, rule.name, msg);
        }
    }

    return .ok;
}

fn checkIntRange(value: i64, rule: lexer.Validator) SchemaError!?[]const u8 {
    if (rule.params.len == 0) return error.InvalidParameterCount;
    const bound = zstd.fmt.parseInt(i64, rule.params[0].value, 10) catch return error.InvalidParameterType;
    if (zstd.mem.eql(u8, rule.name, "min") and value < bound) return "Value is below minimum";
    if (zstd.mem.eql(u8, rule.name, "max") and value > bound) return "Value exceeds maximum";
    return null;
}

fn toValue(buf: []u8, field_value: anytype) SchemaError!engine.Value {
    const value = engine.Value.fromAny(field_value);
    if (value != .other) return value;

    const s = zstd.fmt.bufPrint(buf, "{any}", .{field_value}) catch return error.NoSpaceLeft;
    return .{ .string = s };
}

fn messageFor(
    spec: *const lexer.Specification,
    rule_name: []const u8,
    fallback: []const u8,
) []const u8 {
    for (spec.messages) |msg| {
        const name = if (msg.name.len > 0 and msg.name[0] == '@') msg.name[1..] else msg.name;
        if (zstd.mem.eql(u8, name, rule_name)) return msg.message;
    }
    return fallback;
}

fn fail(
    allocator: zstd.mem.Allocator,
    path_prefix: []const u8,
    field_name: []const u8,
    rule: []const u8,
    message: []const u8,
) SchemaError!Outcome {
    const path = try joinPath(allocator, path_prefix, field_name);
    return .{
        .err = .{
            .path = path,
            .rule = rule,
            .message = message,
        },
    };
}

test "schema" {
    const Test = struct {
        name: []const u8,
        run_test: *const fn (allocator: zstd.mem.Allocator) anyerror!void,
    };

    const testcases: []const Test = &.{
        .{
            .name = "docOf prefers doc then documentation",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    _ = allocator;
                    const Both = struct {
                        pub const doc: []const u8 = "doc";
                        pub const documentation: []const u8 = "documentation";
                        x: u8,
                    };
                    const OnlyDoc = struct {
                        pub const documentation: []const u8 = "documentation";
                        x: u8,
                    };
                    const None = struct { x: u8 };
                    try zstd.testing.expectEqualStrings("doc", docOf(Both));
                    try zstd.testing.expectEqualStrings("documentation", docOf(OnlyDoc));
                    try zstd.testing.expectEqualStrings("", docOf(None));
                }
            }.executor,
        },
        .{
            .name = "scanValidatorNames extracts rules from @validator lines",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    _ = allocator;
                    const names = scanValidatorNames(
                        \\// @property: name
                        \\//   @validator: @required,@min_length=1,@email
                        \\//   @messages:
                        \\//     required - "Name is required"
                    );
                    try zstd.testing.expectEqual(@as(usize, 3), names.len);
                    try zstd.testing.expectEqualStrings("required", names[0]);
                    try zstd.testing.expectEqualStrings("min_length", names[1]);
                    try zstd.testing.expectEqualStrings("email", names[2]);
                    try zstd.testing.expect(isAllowedValidator("required", &.{}));
                    try zstd.testing.expect(!isAllowedValidator("endswith", &.{}));
                    try zstd.testing.expect(isAllowedValidator("endswith", &.{"endswith"}));
                }
            }.executor,
        },
        .{
            .name = "ensureRegistered rejects unregistered validators",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const Item = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: kind
                            \\//   @validator: @endswith=er
                        ;
                        kind: []const u8,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var compiled = try Schema(Item).compile(allocator, null);
                    defer compiled.deinit();
                    try zstd.testing.expectError(error.ValidatorNotFound, compiled.ensureRegistered(&eng));
                    try register(&eng, "endswith", struct {
                        fn endswith(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
                            _ = ctx;
                            return engine.ValidationResult.success();
                        }
                    }.endswith);
                    try compiled.ensureRegistered(&eng);
                }
            }.executor,
        },

        .{
            .name = "defaultEngine + Schema compile once and validate",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const User = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: name
                            \\//   @validator: @alpha,@min_length=2,@max_length=56
                            \\//   @messages:
                            \\//     @alpha - "Must be alphabetic only"
                            \\//     @min_length - "Name must be at least 2 characters"
                            \\//     @max_length - "Name cannot exceed 56 characters"
                            \\// @property: age
                            \\//   @validator: @numeric,@min=10,@max=130
                            \\//   @messages:
                            \\//     @min - "Age must be at least 10"
                            \\//     @max - "Age cannot exceed 130"
                        ;
                        name: []const u8,
                        age: i32,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var schema = try Schema(User).compile(allocator, null);
                    defer schema.deinit();
                    const ok_user = User{ .name = "Joe", .age = 25 };
                    const ok = try schema.validate(&eng, ok_user);
                    defer ok.deinit(allocator);
                    try zstd.testing.expect(ok == .ok);
                    const bad_user = User{ .name = "J", .age = 25 };
                    const bad = try schema.validate(&eng, bad_user);
                    defer bad.deinit(allocator);
                    try zstd.testing.expect(bad == .err);
                    try zstd.testing.expectEqualStrings("name", bad.err.path);
                    try zstd.testing.expectEqualStrings("min_length", bad.err.rule);
                }
            }.executor,
        },

        .{
            .name = "external source overrides embedded doc",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const Product = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: name
                            \\//   @validator: @required,@min_length=100
                            \\//   @messages:
                            \\//     @min_length - "embedded requires 100"
                        ;
                        name: []const u8,
                        price: i32,
                    };
                    const external =
                        \\// @validation
                        \\// @property: name
                        \\//   @validator: @required,@min_length=3
                        \\//   @messages:
                        \\//     @min_length - "external requires 3"
                        \\// @property: price
                        \\//   @validator: @min=0
                        \\//   @messages:
                        \\//     @min - "Price must be non-negative"
                    ;
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var schema = try Schema(Product).compile(allocator, external);
                    defer schema.deinit();
                    const product = Product{ .name = "Widget", .price = 10 };
                    const outcome = try schema.validate(&eng, product);
                    defer outcome.deinit(allocator);
                    try zstd.testing.expect(outcome == .ok);
                }
            }.executor,
        },

        .{
            .name = "nested structs reuse shared engine without registry copy",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const User = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: name
                            \\//   @validator: @required,@alpha
                            \\//   @messages:
                            \\//     @required - "Name is required"
                            \\//     @alpha - "Name must be alphabetic"
                        ;
                        name: []const u8,
                        address: struct {
                            pub const doc: []const u8 =
                                \\// @validation
                                \\// @property: street
                                \\//   @validator: @required,@min_length=5
                                \\//   @messages:
                                \\//     @required - "Street is required"
                                \\//     @min_length - "Street must be at least 5 characters"
                                \\// @property: city
                                \\//   @validator: @required,@alpha
                                \\//   @messages:
                                \\//     @required - "City is required"
                                \\//     @alpha - "City must be alphabetic"
                            ;
                            street: []const u8,
                            city: []const u8,
                        },
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var schema = try Schema(User).compile(allocator, null);
                    defer schema.deinit();
                    const user = User{
                        .name = "John",
                        .address = .{
                            .street = "Main Street",
                            .city = "Boston",
                        },
                    };
                    const ok = try schema.validate(&eng, user);
                    defer ok.deinit(allocator);
                    try zstd.testing.expect(ok == .ok);
                    const bad = User{
                        .name = "John",
                        .address = .{
                            .street = "Main Street",
                            .city = "Boston123",
                        },
                    };
                    const failed = try schema.validate(&eng, bad);
                    defer failed.deinit(allocator);
                    try zstd.testing.expect(failed == .err);
                    try zstd.testing.expectEqualStrings("address.city", failed.err.path);
                    try zstd.testing.expectEqualStrings("alpha", failed.err.rule);
                }
            }.executor,
        },
        .{
            .name = "nested structs reuse shared engine without registry copy",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const Address = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: street
                            \\//   @validator: @required,@min_length=5
                            \\//   @messages:
                            \\//     @required - "Street is required"
                            \\//     @min_length - "Street must be at least 5 characters"
                            \\// @property: city
                            \\//   @validator: @required,@alpha
                            \\//   @messages:
                            \\//     @required - "City is required"
                            \\//     @alpha - "City must be alphabetic"
                        ;
                        street: []const u8,
                        city: []const u8,
                    };
                    const User = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: name
                            \\//   @validator: @required,@alpha
                            \\//   @messages:
                            \\//     @required - "Name is required"
                            \\//     @alpha - "Name must be alphabetic"
                        ;
                        name: []const u8,
                        address: Address,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var schema = try Schema(User).compile(allocator, null);
                    defer schema.deinit();
                    const user = User{
                        .name = "John",
                        .address = .{
                            .street = "Main Street",
                            .city = "Boston",
                        },
                    };
                    const ok = try schema.validate(&eng, user);
                    defer ok.deinit(allocator);
                    try zstd.testing.expect(ok == .ok);
                    const bad = User{
                        .name = "John",
                        .address = .{
                            .street = "Main Street",
                            .city = "Boston123",
                        },
                    };
                    const failed = try schema.validate(&eng, bad);
                    defer failed.deinit(allocator);
                    try zstd.testing.expect(failed == .err);
                    try zstd.testing.expectEqualStrings("address.city", failed.err.path);
                    try zstd.testing.expectEqualStrings("alpha", failed.err.rule);
                }
            }.executor,
        },
        .{
            .name = "typed int path rejects out-of-range without string parse for min",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const Config = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: port
                            \\//   @validator: @min=1,@max=65535
                            \\//   @messages:
                            \\//     @min - "port too small"
                            \\//     @max - "port too large"
                        ;
                        port: i32,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    var schema = try Schema(Config).compile(allocator, null);
                    defer schema.deinit();
                    const failed = try schema.validate(&eng, Config{ .port = 0 });
                    defer failed.deinit(allocator);
                    try zstd.testing.expect(failed == .err);
                    try zstd.testing.expectEqualStrings("port", failed.err.path);
                    try zstd.testing.expectEqualStrings("min", failed.err.rule);
                    try zstd.testing.expectEqualStrings("port too small", failed.err.message);
                }
            }.executor,
        },
        .{
            .name = "custom validator on shared engine",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const Item = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: kind
                            \\//   @validator: @endswith=er
                            \\//   @messages:
                            \\//     @endswith - "must end with er"
                        ;
                        kind: []const u8,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    try register(&eng, "endswith", struct {
                        fn endswith(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
                            if (ctx.params.len != 1) return error.InvalidParameterCount;
                            const s = ctx.value.asString() orelse {
                                return engine.ValidationResult.failure("suffix mismatch");
                            };
                            if (zstd.mem.endsWith(u8, s, ctx.params[0].value)) {
                                return engine.ValidationResult.success();
                            }
                            return engine.ValidationResult.failure("suffix mismatch");
                        }
                    }.endswith);
                    var schema = try Schema(Item).compile(allocator, null);
                    defer schema.deinit();
                    const ok = try schema.validate(&eng, Item{ .kind = "runner" });
                    defer ok.deinit(allocator);
                    try zstd.testing.expect(ok == .ok);
                    const bad = try schema.validate(&eng, Item{ .kind = "run" });
                    defer bad.deinit(allocator);
                    try zstd.testing.expect(bad == .err);
                    try zstd.testing.expectEqualStrings("endswith", bad.err.rule);
                }
            }.executor,
        },
        .{
            .name = "nested pointer configs with custom url validator",
            .run_test = struct {
                fn executor(allocator: zstd.mem.Allocator) anyerror!void {
                    const DatabaseConfig = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: host
                            \\//   @validator: @required,@min_length=1
                            \\// @property: port
                            \\//   @validator: @required,@min=1024,@max=65535
                            \\//   @messages:
                            \\//     @min - "Port must be at least 1024"
                            \\// @property: name
                            \\//   @validator: @required,@min_length=1
                            \\// @property: user
                            \\//   @validator: @required,@min_length=1
                            \\// @property: password
                            \\//   @validator: @required,@min_length=8
                            \\// @property: url
                            \\//   @validator: @required,@min_length=10
                            \\// @property: external_port
                            \\//   @validator: @required,@min=1024,@max=65535
                            \\// @property: external_host
                            \\//   @validator: @required,@min_length=1
                        ;
                        host: []const u8,
                        port: i32,
                        name: []const u8,
                        user: []const u8,
                        password: []const u8,
                        url: []const u8,
                        external_port: i32,
                        external_host: []const u8,
                    };
                    const ApiConfig = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: prefix
                            \\//   @validator: @required,@alpha,@min_length=1,@max_length=20
                            \\// @property: version
                            \\//   @validator: @required,@min_length=1,@max_length=10
                        ;
                        prefix: []const u8,
                        version: []const u8,
                    };
                    const FirebaseConfig = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: app_name
                            \\//   @validator: @required,@min_length=1
                        ;
                        database_url: ?[]const u8 = null,
                        project_id: ?[]const u8 = null,
                        app_name: []const u8,
                    };
                    const SlackConfig = struct {
                        bot_token: ?[]const u8 = null,
                    };
                    const EmailConfig = struct {
                        sendgrid_api_key: ?[]const u8 = null,
                    };
                    const SmsConfig = struct {
                        provider_name: ?[]const u8 = null,
                    };
                    const AppConfig = struct {
                        pub const doc: []const u8 =
                            \\// @validation
                            \\// @property: node_env
                            \\//   @validator: @required,@alpha,@min_length=1
                            \\//   @messages:
                            \\//     @required - "Node environment is required"
                            \\//     @alpha - "Node environment must be alphabetic"
                            \\//     @min_length - "Node environment cannot be empty"
                            \\// @property: port
                            \\//   @validator: @required,@min=1024,@max=65535
                            \\//   @messages:
                            \\//     @required - "Application port is required"
                            \\//     @min - "Port must be at least 1024"
                            \\//     @max - "Port cannot exceed 65535"
                            \\// @property: log_level
                            \\//   @validator: @required,@alpha,@min_length=1
                            \\//   @messages:
                            \\//     @required - "Log level is required"
                            \\//     @alpha - "Log level must be alphabetic"
                            \\//     @min_length - "Log level cannot be empty"
                            \\// @property: compose_project_name
                            \\//   @validator: @required,@min_length=1
                            \\//   @messages:
                            \\//     @required - "Compose project name is required"
                            \\//     @min_length - "Compose project name cannot be empty"
                            \\// @property: redis_url
                            \\//   @validator: @required,@url,@min_length=10
                            \\//   @messages:
                            \\//     @required - "Redis URL is required"
                            \\//     @url - "The value must be a valid URL"
                            \\//     @min_length - "Redis URL must be at least 10 characters"
                        ;
                        node_env: []const u8,
                        port: i32,
                        log_level: []const u8,
                        compose_project_name: []const u8,
                        redis_url: []const u8,
                        email: *EmailConfig,
                        db: *DatabaseConfig,
                        api: *ApiConfig,
                        firebase: *FirebaseConfig,
                        slack: *SlackConfig,
                        sms: *SmsConfig,
                    };
                    var email = EmailConfig{ .sendgrid_api_key = "SGabcdefghijklmnopqrstuvwx" };
                    var db = DatabaseConfig{
                        .host = "postgres",
                        .port = 5432,
                        .name = "circle_market_dev",
                        .user = "circle_market_user",
                        .password = "circle_market_password",
                        .url = "postgresql://postgres:5432/circle_market_dev",
                        .external_port = 5433,
                        .external_host = "localhost",
                    };
                    var api = ApiConfig{ .prefix = "api", .version = "v1" };
                    var firebase = FirebaseConfig{ .app_name = "[DEFAULT]" };
                    var slack = SlackConfig{ .bot_token = "xoxb-token" };
                    var sms = SmsConfig{ .provider_name = "twilio" };
                    const valid = AppConfig{
                        .node_env = "development",
                        .port = 3000,
                        .log_level = "debug",
                        .compose_project_name = "circle-market-backend",
                        .redis_url = "redis://redis:6379",
                        .email = &email,
                        .db = &db,
                        .api = &api,
                        .firebase = &firebase,
                        .slack = &slack,
                        .sms = &sms,
                    };
                    var eng = try DefaultEngine(allocator);
                    defer eng.deinit();
                    try register(&eng, "url", struct {
                        fn url(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
                            const s = ctx.value.asString() orelse {
                                return engine.ValidationResult.failure("Failed to validate URL format");
                            };
                            if (zstd.mem.indexOf(u8, s, "://") != null) {
                                return engine.ValidationResult.success();
                            }
                            return engine.ValidationResult.failure("Failed to validate URL format");
                        }
                    }.url);
                    var schema = try Schema(AppConfig).compile(allocator, null);
                    defer schema.deinit();
                    const ok = try schema.validate(&eng, valid);
                    defer ok.deinit(allocator);
                    if (ok != .ok) {
                        zstd.debug.print(
                            "expected ok, got err path={s} rule={s} msg={s}\n",
                            .{ ok.err.path, ok.err.rule, ok.err.message },
                        );
                    }
                    try zstd.testing.expect(ok == .ok);
                    var bad_env = valid;
                    bad_env.node_env = "dev-1";
                    const bad = try schema.validate(&eng, bad_env);
                    defer bad.deinit(allocator);
                    try zstd.testing.expect(bad == .err);
                    try zstd.testing.expectEqualStrings("node_env", bad.err.path);
                    try zstd.testing.expectEqualStrings("alpha", bad.err.rule);
                    try zstd.testing.expectEqualStrings("Node environment must be alphabetic", bad.err.message);
                    var bad_port = valid;
                    bad_port.port = 80;
                    const bad2 = try schema.validate(&eng, bad_port);
                    defer bad2.deinit(allocator);
                    try zstd.testing.expect(bad2 == .err);
                    try zstd.testing.expectEqualStrings("port", bad2.err.path);
                    try zstd.testing.expectEqualStrings("min", bad2.err.rule);
                    try zstd.testing.expectEqualStrings("Port must be at least 1024", bad2.err.message);
                    var bad_log = valid;
                    bad_log.log_level = "debug2";
                    const bad3 = try schema.validate(&eng, bad_log);
                    defer bad3.deinit(allocator);
                    try zstd.testing.expect(bad3 == .err);
                    try zstd.testing.expectEqualStrings("log_level", bad3.err.path);
                    try zstd.testing.expectEqualStrings("alpha", bad3.err.rule);
                    var bad_db = db;
                    bad_db.port = 80;
                    var bad_nested = valid;
                    bad_nested.db = &bad_db;
                    const bad4 = try schema.validate(&eng, bad_nested);
                    defer bad4.deinit(allocator);
                    try zstd.testing.expect(bad4 == .err);
                    try zstd.testing.expectEqualStrings("db.port", bad4.err.path);
                    try zstd.testing.expectEqualStrings("min", bad4.err.rule);
                }
            }.executor,
        },
    };

    const allocator = zstd.testing.allocator;
    for (testcases) |testcase| {
        try testcase.run_test(allocator);
    }
}
