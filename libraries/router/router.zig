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
) anyerror!void;

const Route = struct {
    method: Method,
    pattern: []const u8,
    handler: HandlerFn,
};

pub const Router = struct {
    allocator: Allocator,
    routes: zstd.ArrayList(Route) = .empty,

    var active: ?*Router = null;

    pub fn init(allocator: Allocator) Router {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit(self.allocator);
        if (active == self) active = null;
        self.* = undefined;
    }

    pub fn register(
        self: *Router,
        method: Method,
        pattern: []const u8,
        comptime Def: type,
    ) !void {
        const handler = struct {
            fn handle(
                allocator: Allocator,
                request: zap.Request,
                path_params: *const match.PathParams,
            ) !void {
                var ctx = try bind.RequestContext.fromZap(
                    allocator,
                    request,
                    path_params,
                );
                defer ctx.deinit();
                try action.Action(Def).handle(allocator, request, &ctx);
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

            if (!try match.matchPath(
                arena_allocator,
                route.pattern,
                path,
                &path_params,
            )) {
                continue;
            }

            try route.handler(arena_allocator, request, &path_params);
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
