const zstd = @import("std");
const zap = @import("zap");
const action = @import("action.zig");
const bind = @import("bind.zig");
const match = @import("match.zig");

const Allocator = zstd.mem.Allocator;
const Method = match.Method;

const HandlerFn = *const fn (
    allocator: Allocator,
    request: zap.Request,
    path_params: *const match.PathParams,
    dependencies: *anyopaque,
) anyerror!void;

const Route = struct {
    method: Method,
    pattern: []const u8,
    handler: HandlerFn, // should be an interface to a chain of known
};

fn isAction(comptime T: type) bool {
    const hasRun = @hasDecl(T, "run");
    const hasExit = @hasDecl(T, "Exit");
    const hasInputs = @hasDecl(T, "Inputs");
    return hasRun and hasExit and hasInputs;
}

pub const Router = struct {
    allocator: Allocator,
    dependencies: *anyopaque,
    routes: zstd.ArrayList(Route) = .empty,

    var active: ?*Router = null;

    pub fn init(allocator: Allocator, dependencies: *anyopaque) Router {
        return .{
            .allocator = allocator,
            .dependencies = dependencies,
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        if (active == self) active = null;
        self.* = undefined;
    }

    pub fn register(self: *Router, method: Method, pattern: []const u8, comptime chain_or_def: anytype) !void {
        const handler = struct {
            fn handle(
                allocator: Allocator,
                request: zap.Request,
                path_params: *const match.PathParams,
                dependencies: *anyopaque,
            ) !void {
                var ctx = try bind.RequestContext.fromZap(allocator, request, path_params, dependencies);
                defer ctx.deinit();

                const chain = if (@TypeOf(chain_or_def) == type) .{chain_or_def} else chain_or_def;
                inline for (chain) |Step| {
                    if (comptime isAction(Step)) {
                        try action.Action(Step).handle(allocator, request, &ctx);
                        return;
                    } else {
                        const keep_going = try Step.handle(allocator, request, &ctx);
                        if (!keep_going) break;
                    }
                }
            }
        }.handle;

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
        });
    }

    pub fn onRequestHandler(self: *Router) zap.HttpRequestFn {
        active = self;
        return onRequestCallback;
    }

    pub fn onRequest(self: *Router, request: zap.Request) !void {
        const path = request.path orelse "/";
        const method = match.methodFromRequest(request.method);

        var arena = zstd.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            var path_params: match.PathParams = .{};
            defer match.freePathParams(arena_allocator, &path_params);

            if (!try match.matchPath(arena_allocator, route.pattern, path, &path_params)) {
                continue;
            }

            try route.handler(arena_allocator, request, &path_params, self.dependencies);
            return;
        }

        request.setStatus(.not_found);
        try request.sendJson("{\"error_message\":\"not found\"}");
    }

    fn onRequestCallback(request: zap.Request) !void {
        const router = active orelse {
            request.setStatus(.internal_server_error);
            try request.sendJson("{\"error_message\":\"router not initialized\"}");
            return;
        };
        try router.onRequest(request);
    }
};
