const std = @import("std");
const action = @import("../action.zig");
const bind = @import("../bind.zig");
const engine = @import("../../validation/engine.zig");
const testing = std.testing;

pub const Hello = struct {
    pub const friendly_name = "Hello";
    pub const description = "Echo a name from query/body/path params";

    pub const Inputs = struct {
        pub const doc: []const u8 =
            \\// @validation
            \\// @property: name
            \\//   @validator: @required,@min_length=1,@endswith=".com"
            \\//   @messages:
            \\//     @required - "Name is required"
            \\//     @min_length - "Name must be at least 1 character"
            \\//     @endswith - "Name must end with .com"
        ;

        name: []const u8 = "world.com",
    };

    pub const validators = struct {
        pub const endswith = struct {
            pub fn validate(ctx: engine.Context) engine.ValidationReturnType {
                if (ctx.params.len != 1) return error.InvalidParameterCount;
                const value = ctx.value.asString() orelse {
                    return engine.ValidationResult.failure("must be a string");
                };
                const suffix = ctx.params[0].asString() orelse return error.InvalidParameterType;
                if (std.mem.endsWith(u8, value, suffix)) {
                    return engine.ValidationResult.success();
                }
                return engine.ValidationResult.failure("suffix mismatch");
            }
        }.validate;
    };

    pub const Exit = enum { success, badRequest };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{
                .status = .ok,
                .response_type = .json,
            },
            .badRequest => .{
                .status = .bad_request,
                .response_type = .json,
            },
        };
    }

    pub fn run(inputs: Inputs, exits: *action.Exits(@This())) !void {
        if (inputs.name.len == 0) {
            return exits.send(.badRequest, .{
                .error_message = "name required",
            });
        }
        return exits.send(.success, .{
            .message = inputs.name,
        });
    }
};

test "hello action default name" {
    var ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();

    var capture: action.Capture = .{};
    defer capture.deinit();

    try action.Action(Hello).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("success", capture.exit_tag);
    try testing.expect(std.mem.indexOf(u8, capture.body, "world") != null);
}

test "hello action path name" {
    var ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello/ada",
    };
    defer ctx.deinit();
    try ctx.put("name", "ada.com");

    var capture: action.Capture = .{};
    defer capture.deinit();

    try action.Action(Hello).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("success", capture.exit_tag);
    try testing.expect(std.mem.indexOf(u8, capture.body, "ada") != null);
}

test "hello action validation error is sent" {
    var ctx = bind.RequestContext{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    defer ctx.deinit();
    try ctx.put("name", "");

    var capture: action.Capture = .{};
    defer capture.deinit();

    try action.Action(Hello).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("badRequest", capture.exit_tag);
    try testing.expect(std.mem.indexOf(u8, capture.body, "validation failed") != null);
    try testing.expect(std.mem.indexOf(u8, capture.body, "Name is required") != null);
}
