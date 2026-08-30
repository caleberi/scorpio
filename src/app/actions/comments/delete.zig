const libraries = @import("libraries");
const state = @import("../../state.zig");

const action = libraries.router.action;

pub const Delete = struct {
    pub const friendly_name = "DeleteComment";
    pub const description = "Delete a comment on a blog post";

    pub const Inputs = struct {
        slug: []const u8,
        comment_id: []const u8,
    };
    pub const Exit = enum { success, notFound, error_ };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{ .status = .ok, .response_type = .json },
            .notFound => .{ .status = .not_found, .response_type = .json },
            .error_ => .{ .status = .internal_server_error, .response_type = .json },
        };
    }

    pub fn run(inputs: Inputs, exits: *action.Exits(@This())) !void {
        const app = exits.deps(state.State);
        const blog_id = (try app.db.blogIdBySlug(exits.allocator, inputs.slug)) orelse {
            return exits.send(.notFound, .{ .error_message = "This post isn't set up for comments yet." });
        };
        defer exits.allocator.free(blog_id);

        const ok = app.db.deleteComment(blog_id, inputs.comment_id) catch {
            return exits.send(.error_, .{ .error_message = "failed to delete comment" });
        };
        if (!ok) return exits.send(.notFound, .{ .error_message = "comment not found" });
        return exits.send(.success, .{ .deleted = true });
    }
};
