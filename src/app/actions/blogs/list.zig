const std = @import("std");
const libraries = @import("libraries");
const state = @import("../../state.zig");

const action = libraries.router.action;

pub const List = struct {
    pub const friendly_name = "ListBlog";
    pub const description = "List packed blog documents from the local manifest";

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
            path: []const u8,
            modified_at: i64,
            length: u64,
        };
        var docs: std.ArrayList(Listing) = .empty;
        defer docs.deinit(exits.allocator);
        for (app.manifest.data.documents) |doc| {
            try docs.append(exits.allocator, .{
                .slug = doc.slug,
                .path = doc.path,
                .modified_at = doc.modified_at,
                .length = doc.length,
            });
        }
        return exits.send(.success, .{ .documents = docs.items });
    }
};
