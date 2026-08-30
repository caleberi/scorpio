const libraries = @import("libraries");
const state = @import("../../state.zig");

const action = libraries.router.action;

pub const Get = struct {
    pub const friendly_name = "GetBlog";
    pub const description = "Fetch a packed blog document by slug from Cloudinary";

    pub const Inputs = struct {
        slug: []const u8,
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
        const doc = app.findDocument(inputs.slug) orelse {
            return exits.send(.notFound, .{
                .error_message = "We couldn't find that post. It may have moved, or the link is incomplete.",
            });
        };

        const content = app.cache.getDocument(inputs.slug) catch |err| switch (err) {
            error.NotFound => return exits.send(.notFound, .{
                .error_message = "We couldn't find that post. It may have moved, or the link is incomplete.",
            }),
            else => return exits.send(.error_, .{ .error_message = "Something went wrong loading this post. Try again in a moment." }),
        };

        const neighbors = app.neighborSlugs(inputs.slug, exits.allocator) catch {
            return exits.send(.error_, .{ .error_message = "failed to resolve neighbors" });
        };
        defer exits.allocator.free(neighbors);
        app.cache.prefetch(neighbors);

        return exits.send(.success, .{
            .slug = doc.slug,
            .path = doc.path,
            .modified_at = doc.modified_at,
            .length = doc.length,
            .content = content,
            .prefetch = neighbors,
        });
    }
};
