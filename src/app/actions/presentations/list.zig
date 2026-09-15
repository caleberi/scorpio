const std = @import("std");
const libraries = @import("libraries");
const state = @import("../../state.zig");

const action = libraries.router.action;

pub const List = struct {
    pub const friendly_name = "ListPresentations";
    pub const description = "List compiled presentation decks";

    pub const Inputs = struct {};
    pub const Exit = enum { success, error_ };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{ .status = .ok, .response_type = .json },
            .error_ => .{ .status = .internal_server_error, .response_type = .json },
        };
    }

    pub fn run(_: Inputs, exits: *action.Exits(@This())) !void {
        const app = exits.deps(state.State);
        const Listing = struct {
            slug: []const u8,
            title: []const u8,
            path: []const u8,
            duration_ms: i64,
            size: struct { w: u32, h: u32 },
            image: []const u8,
        };
        var docs: std.ArrayList(Listing) = .empty;
        defer docs.deinit(exits.allocator);
        for (app.presentations.data.documents) |doc| {
            try docs.append(exits.allocator, .{
                .slug = doc.slug,
                .title = doc.title,
                .path = doc.path,
                .duration_ms = doc.duration_ms,
                .size = .{ .w = doc.size.w, .h = doc.size.h },
                .image = doc.image,
            });
        }
        return exits.send(.success, .{ .documents = docs.items });
    }
};
