const std = @import("std");
const libraries = @import("libraries");
const state = @import("../../state.zig");
const db_mod = @import("../../blog/db.zig");

const action = libraries.router.action;

pub const List = struct {
    pub const friendly_name = "ListComments";
    pub const description = "List comments and nested replies for a blog post";

    pub const Inputs = struct { slug: []const u8 };
    pub const Exit = enum { success, notFound, error_ };

    pub fn exitMeta(comptime e: Exit) action.ExitMeta {
        return switch (e) {
            .success => .{ .status = .ok, .response_type = .json },
            .notFound => .{ .status = .not_found, .response_type = .json },
            .error_ => .{ .status = .internal_server_error, .response_type = .json },
        };
    }

    pub fn run(inputs: Inputs, exits: *action.Exits(@This())) !void {
        const app = state.get();
        const blog_id = (try app.db.blogIdBySlug(exits.allocator, inputs.slug)) orelse {
            return exits.send(.notFound, .{ .error_message = "This post isn't set up for comments yet." });
        };
        defer exits.allocator.free(blog_id);

        const comments = app.db.listComments(exits.allocator, blog_id) catch {
            return exits.send(.error_, .{ .error_message = "failed to list comments" });
        };
        defer {
            for (comments) |c| db_mod.freeComment(exits.allocator, c);
            exits.allocator.free(comments);
        }

        const CommentOut = struct {
            id: []const u8,
            author: []const u8,
            body: []const u8,
            created_at: []const u8,
            updated_at: []const u8,
            replies: []const db_mod.Reply,
        };

        var out: std.ArrayList(CommentOut) = .empty;
        defer {
            for (out.items) |item| {
                for (item.replies) |r| db_mod.freeReply(exits.allocator, r);
                exits.allocator.free(item.replies);
            }
            out.deinit(exits.allocator);
        }

        for (comments) |c| {
            const replies = app.db.listReplies(exits.allocator, c.id) catch {
                return exits.send(.error_, .{ .error_message = "failed to list replies" });
            };
            try out.append(exits.allocator, .{
                .id = c.id,
                .author = c.author,
                .body = c.body,
                .created_at = c.created_at,
                .updated_at = c.updated_at,
                .replies = replies,
            });
        }

        return exits.send(.success, .{ .comments = out.items });
    }
};
