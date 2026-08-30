const libraries = @import("libraries");
const state = @import("../../state.zig");
const db_mod = @import("../../blog/db.zig");

const action = libraries.router.action;

pub const Create = struct {
    pub const friendly_name = "CreateReply";
    pub const description = "Create a reply on a blog comment";

    pub const Inputs = struct {
        slug: []const u8,
        comment_id: []const u8,
        author: []const u8,
        body: []const u8,
    };
    pub const Exit = enum { success, notFound, badRequest, error_ };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{ .status = .ok, .response_type = .json },
            .notFound => .{ .status = .not_found, .response_type = .json },
            .badRequest => .{ .status = .bad_request, .response_type = .json },
            .error_ => .{ .status = .internal_server_error, .response_type = .json },
        };
    }

    pub fn run(inputs: Inputs, exits: *action.Exits(@This())) !void {
        if (inputs.author.len == 0 or inputs.body.len == 0) {
            return exits.send(.badRequest, .{ .error_message = "author and body required" });
        }
        const app = exits.deps(state.State);
        const blog_id = (try app.db.blogIdBySlug(exits.allocator, inputs.slug)) orelse {
            return exits.send(.notFound, .{ .error_message = "This post isn't set up for comments yet." });
        };
        defer exits.allocator.free(blog_id);

        const reply = (app.db.createReply(exits.allocator, blog_id, inputs.comment_id, inputs.author, inputs.body) catch {
            return exits.send(.error_, .{ .error_message = "failed to create reply" });
        }) orelse {
            return exits.send(.notFound, .{ .error_message = "comment not found" });
        };
        defer db_mod.freeReply(exits.allocator, reply);
        return exits.send(.success, reply);
    }
};
