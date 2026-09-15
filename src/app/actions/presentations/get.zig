const std = @import("std");
const libraries = @import("libraries");
const state = @import("../../state.zig");

const action = libraries.router.action;
const fs = libraries.fs;
const deck_mod = libraries.processor.presentation.deck;

pub const Get = struct {
    pub const friendly_name = "GetPresentation";
    pub const description = "Fetch a compiled presentation deck by slug";

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
        const entry = app.presentations.get(inputs.slug) orelse {
            return exits.send(.notFound, .{
                .error_message = "We couldn't find that presentation.",
            });
        };
        _ = entry;

        const rel = try std.fmt.allocPrint(exits.allocator, "{s}.json", .{inputs.slug});
        defer exits.allocator.free(rel);
        const full = try fs.path.join(exits.allocator, &.{ app.config.presentation.pack_dir, rel });
        defer exits.allocator.free(full);

        const bytes = fs.cwd().readFileAlloc(exits.allocator, full, 32 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return exits.send(.notFound, .{
                .error_message = "We couldn't find that presentation.",
            }),
            else => return exits.send(.error_, .{
                .error_message = "Something went wrong loading this presentation.",
            }),
        };
        defer exits.allocator.free(bytes);

        var arena = std.heap.ArenaAllocator.init(exits.allocator);
        defer arena.deinit();
        const deck = deck_mod.deserializeDeck(arena.allocator(), bytes) catch {
            return exits.send(.error_, .{
                .error_message = "Something went wrong loading this presentation.",
            });
        };
        return exits.send(.success, deck);
    }
};
