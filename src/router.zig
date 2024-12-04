const zzz = @import("zzz");
const std = @import("std");
const Agent = @import("./ddog/agent.zig");
const handlers = @import("handlers.zig");
const zhttp = zzz.HTTP;
const Server = zhttp.Server(.plain);
const Router = Server.Router;
const Route = Server.Route;
const Context = Server.Context;
const Dependencies = handlers.Dependencies;

pub fn bindRoutes(router: *Router, deps: *Dependencies) !void {
    try router.serve_route("/trace", Route.init().post(deps, handlers.TraceHandler));
    try router.serve_route("/metric", Route.init().post(deps, handlers.MetricHandler));
    try router.serve_route("/log", Route.init().post(deps, handlers.TraceHandler));
}
