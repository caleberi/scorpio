const zzz = @import("zzz");
const std = @import("std");
const Agent = @import("./ddog/agent.zig");
const zhttp = zzz.HTTP;
const Server = zhttp.Server(.plain);
const Router = Server.Router;
const Route = Server.Route;
const Context = Server.Context;
const Handlers = @import("handlers.zig");
const Dependencies = Handlers.Dependencies;

pub fn bindRoutes(router: *Router, deps: *Dependencies) !void {
    try router.serve_route("/trace", Route.init().post(deps, Handlers.TraceHandler));
    try router.serve_route("/metric", Route.init().post(deps, Handlers.TraceHandler));
    try router.serve_route("/log", Route.init().post(deps, Handlers.TraceHandler));
}
