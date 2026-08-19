const zstd = @import("std");
const zap = @import("zap");
const common = @import("common");
const bind = @import("bind.zig");
const testing = zstd.testing;

pub const ResponseType = enum { json, text, redirect, empty };

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
    // Def must have an Exit enum and a run function
    const Exit = Def.Exit;

    return struct {
        const Self = @This();

        allocator: zstd.mem.Allocator,
        request: ?zap.Request = null,
        capture: ?*Capture = null,
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

fn renderPayload(
    allocator: zstd.mem.Allocator,
    comptime response_type: ResponseType,
    payload: anytype,
) ![]u8 {
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

fn validateAction(comptime Def: type) void {
    if (!@hasDecl(Def, "Inputs")) @compileError(@typeName(Def) ++ " missing Inputs");
    if (!@hasDecl(Def, "Exit")) @compileError(@typeName(Def) ++ " missing Exit");
    if (!@hasDecl(Def, "exitMeta")) @compileError(@typeName(Def) ++ " missing exitMeta");
    if (!@hasDecl(Def, "run")) @compileError(@typeName(Def) ++ " missing run");
    if (@typeInfo(Def.Exit) != .@"enum") @compileError(@typeName(Def) ++ ".Exit must be an enum");
    if (@typeInfo(Def.Inputs) != .@"struct") @compileError(@typeName(Def) ++ ".Inputs must be a struct");
}

pub fn Action(comptime Def: type) type {
    comptime validateAction(Def);

    return struct {
        pub const definition = Def;

        pub fn resolve(
            allocator: zstd.mem.Allocator,
            ctx: *const bind.RequestContext,
            request: ?zap.Request,
            capture: ?*Capture,
        ) !void {
            const inputs = bind.bind(Def.Inputs, ctx) catch |err| {
                try sendBindError(allocator, request, capture, err);
                return;
            };

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

fn sendBindError(
    allocator: zstd.mem.Allocator,
    request: ?zap.Request,
    capture: ?*Capture,
    err: bind.BindError,
) !void {
    const payload = .{
        .error_message = switch (err) {
            error.MissingField => "missing required input",
            error.InvalidValue => "invalid input value",
            error.OutOfMemory => "out of memory",
        },
    };
    const body = try zstd.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(body);

    if (capture) |cap| {
        if (cap.body.len > 0) {
            if (cap.allocator) |a| a.free(cap.body);
        }
        cap.allocator = allocator;
        cap.exit_tag = "badRequest";
        cap.status = .bad_request;
        cap.response_type = .json;
        cap.body = try allocator.dupe(u8, body);
        return;
    }

    const req = request orelse return;
    req.setStatus(.bad_request);
    try req.sendJson(body);
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
