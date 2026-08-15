const std = @import("std");
const action = @import("../action.zig");
const bind = @import("../bind.zig");
const testing = std.testing;

pub const Hello = struct {
    pub const friendly_name = "Hello";
    pub const description = "Echo a name from query/body/path params";

    pub const Inputs = struct {
        name: []const u8 = "world",
    };

    pub const Exit = enum { success, badRequest };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{ .status = .ok, .response_type = .json },
            .badRequest => .{ .status = .bad_request, .response_type = .json },
        };
    }

    pub fn run(inputs: Inputs, exits: *action.Exits(@This())) !void {
        if (inputs.name.len == 0) {
            return exits.send(.badRequest, .{ .error_message = "name required" });
        }
        return exits.send(.success, .{ .message = inputs.name });
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
    try ctx.put("name", "ada");

    var capture: action.Capture = .{};
    defer capture.deinit();

    try action.Action(Hello).resolve(testing.allocator, &ctx, null, &capture);
    try testing.expectEqualStrings("success", capture.exit_tag);
    try testing.expect(std.mem.indexOf(u8, capture.body, "ada") != null);
}
