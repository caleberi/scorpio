const zstd = @import("std");
const zap = @import("zap");
const bind = @import("bind.zig");
const schema = @import("../validation/schema.zig");
const engine = schema.engine;
const testing = zstd.testing;

pub const ResponseType = enum {
    json,
    text,
    redirect,
    empty,
};

pub const ExitMeta = struct {
    status: zap.http.StatusCode = .ok,
    response_type: ResponseType = .json,
};

pub const Capture = struct {
    exit_tag: []const u8 = "",
    status: zap.http.StatusCode = .ok,
    response_type: ResponseType = .json,
    body: []u8 = &.{},
    allocator: ?zstd.mem.Allocator = null,

    pub fn deinit(self: *Capture) void {
        if (self.allocator) |a| {
            if (self.body.len > 0) a.free(self.body);
        }
        self.* = .{};
    }
};

pub fn Exits(comptime Def: type) type {
    const Exit = Def.Exit;

    return struct {
        const Self = @This();

        request: ?zap.Request = null,
        capture: ?*Capture = null,
        allocator: zstd.mem.Allocator,
        sent: bool = false,

        pub fn initZap(allocator: zstd.mem.Allocator, request: zap.Request) Self {
            return .{
                .allocator = allocator,
                .request = request,
            };
        }

        pub fn initCapture(allocator: zstd.mem.Allocator, capture: *Capture) Self {
            capture.allocator = allocator;
            return .{
                .allocator = allocator,
                .capture = capture,
            };
        }

        pub fn send(self: *Self, comptime exit: Exit, payload: anytype) !void {
            if (self.sent) return error.ExitAlreadySent;
            self.sent = true;

            const meta = comptime Def.exitMeta(exit);
            const body = try renderPayload(
                self.allocator,
                meta.response_type,
                payload,
            );
            defer self.allocator.free(body);

            if (self.capture) |cap| {
                if (cap.body.len > 0) cap.allocator.?.free(cap.body);
                cap.exit_tag = @tagName(exit);
                cap.status = meta.status;
                cap.response_type = meta.response_type;
                cap.body = try self.allocator.dupe(u8, body);
                return;
            }

            const request = self.request orelse return error.NoRequest;
            request.setStatus(meta.status);
            switch (meta.response_type) {
                .json => try request.sendJson(body),
                .text => try request.sendBody(body),
                .redirect => try request.redirectTo(body, meta.status),
                .empty => {},
            }
        }
    };
}

fn renderPayload(allocator: zstd.mem.Allocator, comptime response_type: ResponseType, payload: anytype) ![]u8 {
    return switch (response_type) {
        .empty => try allocator.alloc(u8, 0),
        .text, .redirect => try allocator.dupe(u8, asTextPayload(payload)),
        .json => try zstd.json.Stringify.valueAlloc(allocator, payload, .{}),
    };
}

fn asTextPayload(payload: anytype) []const u8 {
    const T = @TypeOf(payload);
    if (comptime T == []const u8 or T == []u8) return payload;
    if (comptime @typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .slice and @typeInfo(T).pointer.child == u8) {
        return payload;
    }
    @compileError("text/redirect exits expect a []const u8 payload");
}

fn extraValidatorNames(comptime Def: type) []const []const u8 {
    if (!@hasDecl(Def, "validators")) return &.{};
    const info = @typeInfo(Def.validators);
    if (info != .@"struct") {
        @compileError(@typeName(Def) ++ ".validators must be a struct of validator functions");
    }
    const decls = info.@"struct".decls;
    if (decls.len == 0) return &.{};

    comptime var names: [decls.len][]const u8 = undefined;
    inline for (decls, 0..) |decl, i| {
        names[i] = decl.name;
    }
    const frozen = names;
    return &frozen;
}

fn registerActionValidators(comptime Def: type, eng: *engine.Engine) schema.SchemaError!void {
    if (!@hasDecl(Def, "validators")) return;
    inline for (@typeInfo(Def.validators).@"struct".decls) |decl| {
        const validator_fn: engine.ValidatorFn = @field(Def.validators, decl.name);
        try schema.register(eng, decl.name, validator_fn);
    }
}

fn validateAction(comptime Def: type) void {
    if (!@hasDecl(Def, "Inputs")) @compileError(@typeName(Def) ++ " missing Inputs");
    if (!@hasDecl(Def, "Exit")) @compileError(@typeName(Def) ++ " missing Exit");
    if (!@hasDecl(Def, "exitMeta")) @compileError(@typeName(Def) ++ " missing exitMeta");
    if (!@hasDecl(Def, "run")) @compileError(@typeName(Def) ++ " missing run");
    if (@typeInfo(Def.Exit) != .@"enum") @compileError(@typeName(Def) ++ ".Exit must be an enum");
    if (@typeInfo(Def.Inputs) != .@"struct") @compileError(@typeName(Def) ++ ".Inputs must be a struct");
    schema.assertKnownValidators(Def.Inputs, extraValidatorNames(Def));
}

pub fn Action(comptime Def: type) type {
    comptime validateAction(Def);

    return struct {
        pub const definition = Def;

        pub fn resolve(allocator: zstd.mem.Allocator, ctx: *const bind.RequestContext, request: ?zap.Request, capture: ?*Capture) !void {
            const inputs = bind.bind(Def.Inputs, ctx) catch |err| {
                try sendBindError(allocator, request, capture, err);
                return;
            };

            var eng = try schema.DefaultEngine(allocator);
            defer eng.deinit();

            try registerActionValidators(Def, &eng);

            var compiled = try schema.Schema(Def.Inputs).compile(allocator, null);
            defer compiled.deinit();

            compiled.ensureRegistered(&eng) catch |err| switch (err) {
                error.ValidatorNotFound => {
                    try sendJsonError(
                        allocator,
                        request,
                        capture,
                        .internal_server_error,
                        "error_",
                        .{ .error_message = "action uses an unregistered validator" },
                    );
                    return;
                },
                else => return err,
            };

            const outcome = compiled.validate(&eng, inputs) catch |err| switch (err) {
                error.ValidatorNotFound => {
                    try sendJsonError(
                        allocator,
                        request,
                        capture,
                        .internal_server_error,
                        "error_",
                        .{ .error_message = "action uses an unregistered validator" },
                    );
                    return;
                },
                else => return err,
            };
            defer outcome.deinit(allocator);
            if (outcome == .err) {
                try sendValidationErrors(allocator, request, capture, &.{outcome.err});
                return;
            }

            var exits: Exits(Def) = if (capture) |cap|
                Exits(Def).initCapture(allocator, cap)
            else if (request) |req|
                Exits(Def).initZap(allocator, req)
            else
                return error.NoRequest;

            try Def.run(inputs, &exits);
            if (!exits.sent) return error.ExitNotSent;
        }

        pub fn handle(
            allocator: zstd.mem.Allocator,
            request: zap.Request,
            ctx: *const bind.RequestContext,
        ) !void {
            try resolve(allocator, ctx, request, null);
        }
    };
}

fn sendJsonError(
    allocator: zstd.mem.Allocator,
    request: ?zap.Request,
    capture: ?*Capture,
    status: zap.http.StatusCode,
    exit_tag: []const u8,
    payload: anytype,
) !void {
    const body = try zstd.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    if (capture) |cap| {
        if (cap.body.len > 0) {
            if (cap.allocator) |a| a.free(cap.body);
        }
        cap.allocator = allocator;
        cap.exit_tag = exit_tag;
        cap.status = status;
        cap.response_type = .json;
        cap.body = try allocator.dupe(u8, body);
        return;
    }

    const req = request orelse return;
    req.setStatus(status);
    try req.sendJson(body);
}

fn sendBindError(
    allocator: zstd.mem.Allocator,
    request: ?zap.Request,
    capture: ?*Capture,
    err: bind.BindError,
) !void {
    try sendJsonError(allocator, request, capture, .bad_request, "badRequest", .{
        .error_message = switch (err) {
            error.MissingField => "missing required input",
            error.InvalidValue => "invalid input value",
            error.OutOfMemory => "out of memory",
        },
    });
}

fn sendValidationErrors(
    allocator: zstd.mem.Allocator,
    request: ?zap.Request,
    capture: ?*Capture,
    errors: []const schema.FieldError,
) !void {
    try sendJsonError(allocator, request, capture, .bad_request, "badRequest", .{
        .error_message = "validation failed",
        .errors = errors,
    });
}

test "exit metadata selection" {
    const Def = struct {
        pub const Inputs = struct {};
        pub const Exit = enum { success, notFound };
        pub fn exitMeta(comptime e: Exit) ExitMeta {
            return switch (e) {
                .success => .{ .status = .ok, .response_type = .json },
                .notFound => .{ .status = .not_found, .response_type = .json },
            };
        }
        pub fn run(_: Inputs, _: *Exits(@This())) !void {}
    };

    try testing.expectEqual(zap.http.StatusCode.ok, Def.exitMeta(.success).status);
    try testing.expectEqual(zap.http.StatusCode.not_found, Def.exitMeta(.notFound).status);
    try testing.expectEqual(ResponseType.json, Def.exitMeta(.success).response_type);
}

test "action run via capture sink" {
    const Def = struct {
        pub const Inputs = struct { name: []const u8 };
        pub const Exit = enum { success, badRequest };

        pub fn exitMeta(comptime e: Exit) ExitMeta {
            return switch (e) {
                .success => .{ .status = .ok, .response_type = .json },
                .badRequest => .{ .status = .bad_request, .response_type = .json },
            };
        }

        pub fn run(inputs: Inputs, exits: *Exits(@This())) !void {
            if (inputs.name.len == 0) {
                return exits.send(.badRequest, .{ .error_message = "name required" });
            }
            return exits.send(.success, .{ .message = inputs.name });
        }
    };

    var ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();
    try ctx.put("name", "zap");

    var capture: Capture = .{};
    defer capture.deinit();

    try Action(Def).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("success", capture.exit_tag);
    try testing.expectEqual(zap.http.StatusCode.ok, capture.status);
    try testing.expect(zstd.mem.indexOf(u8, capture.body, "zap") != null);
}

test "action validation errors are sent as badRequest" {
    const Def = struct {
        pub const Inputs = struct {
            pub const doc: []const u8 =
                \\// @validation
                \\// @property: name
                \\//   @validator: @required,@min_length=3
                \\//   @messages:
                \\//     @required - "Name is required"
                \\//     @min_length - "Name must be at least 3 characters"
            ;
            name: []const u8,
        };
        pub const Exit = enum { success, badRequest };

        pub fn exitMeta(comptime e: Exit) ExitMeta {
            return switch (e) {
                .success => .{ .status = .ok, .response_type = .json },
                .badRequest => .{ .status = .bad_request, .response_type = .json },
            };
        }

        pub fn run(inputs: Inputs, exits: *Exits(@This())) !void {
            return exits.send(.success, .{ .message = inputs.name });
        }
    };

    var ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();
    try ctx.put("name", "ab");

    var capture: Capture = .{};
    defer capture.deinit();

    try Action(Def).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("badRequest", capture.exit_tag);
    try testing.expectEqual(zap.http.StatusCode.bad_request, capture.status);
    try testing.expect(zstd.mem.indexOf(u8, capture.body, "validation failed") != null);
    try testing.expect(zstd.mem.indexOf(u8, capture.body, "min_length") != null);
    try testing.expect(zstd.mem.indexOf(u8, capture.body, "Name must be at least 3 characters") != null);
}

test "action custom validators can be registered on the definition" {
    const Def = struct {
        pub const Inputs = struct {
            pub const doc: []const u8 =
                \\// @validation
                \\// @property: kind
                \\//   @validator: @endswith=er
                \\//   @messages:
                \\//     @endswith - "must end with er"
            ;
            kind: []const u8,
        };
        pub const validators = struct {
            pub fn endswith(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
                if (ctx.params.len != 1) return error.InvalidParameterCount;
                const s = ctx.value.asString() orelse {
                    return engine.ValidationResult.failure("must be a string");
                };
                const suffix = ctx.params[0].asString() orelse return error.InvalidParameterType;
                if (zstd.mem.endsWith(u8, s, suffix)) {
                    return engine.ValidationResult.success();
                }
                return engine.ValidationResult.failure("suffix mismatch");
            }
        };
        pub const Exit = enum { success };

        pub fn exitMeta(comptime e: Exit) ExitMeta {
            return switch (e) {
                .success => .{ .status = .ok, .response_type = .json },
            };
        }

        pub fn run(inputs: Inputs, exits: *Exits(@This())) !void {
            return exits.send(.success, .{ .kind = inputs.kind });
        }
    };

    var ok_ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .POST,
        .path = "/item",
    };
    defer ok_ctx.deinit();
    try ok_ctx.put("kind", "runner");

    var ok_capture: Capture = .{};
    defer ok_capture.deinit();
    try Action(Def).resolve(testing.allocator, &ok_ctx, null, &ok_capture);
    try testing.expectEqualStrings("success", ok_capture.exit_tag);

    var bad_ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .POST,
        .path = "/item",
    };
    defer bad_ctx.deinit();
    try bad_ctx.put("kind", "run");

    var bad_capture: Capture = .{};
    defer bad_capture.deinit();
    try Action(Def).resolve(testing.allocator, &bad_ctx, null, &bad_capture);
    try testing.expectEqualStrings("badRequest", bad_capture.exit_tag);
    try testing.expect(zstd.mem.indexOf(u8, bad_capture.body, "endswith") != null);
    try testing.expect(zstd.mem.indexOf(u8, bad_capture.body, "must end with er") != null);
}
