const std = @import("std");
const Agent = @import("./agent.zig");
const chroma_logger = @import("chroma");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};
const ddog = std.log.scoped(.batch_writer);

fn Params(comptime T: type) type {
    return struct {
        file: []const u8,
        data: T,
    };
}

pub fn GenericBatchWriter(
    comptime T: type,
) type {
    return struct {
        log_file: []const u8,
        event_loop: Tardy,

        pub fn init(allocator: std.mem.Allocator, file: []const u8) !GenericBatchWriter(T) {
            const tardy = try Tardy.init(.{
                .allocator = allocator,
                .threading = .single,
            });

            return .{
                .log_file = file,
                .event_loop = tardy,
            };
        }

        pub fn deinit(self: *Self) void {
            self.event_loop.deinit();
        }

        const Self = @This();

        fn batch_fn(runtime: *Runtime, _: i32, file: *std.fs.File) anyerror!void {
            defer file.*.close();
            const result = try file.*.stat();
            ddog.info("batch_write: size={d}", .{result.size});
            runtime.stop();
        }

        pub fn batch(self: *Self, entry: T) !void {
            const params: Params(T) = Params(T){ .file = self.log_file, .data = entry };
            try self.event_loop.entry(params, struct {
                fn init(runtime: *Runtime, entry_params: Params(T)) !void {
                    const path: []const u8 = entry_params.file;
                    const data: T = entry_params.data;
                    var out = std.ArrayList(u8).init(runtime.allocator);
                    try std.json.stringify(data, .{}, out.writer());
                    ddog.info("path : {any}\n", .{path});
                    ddog.info("data : {any}\n", .{data});
                    var file = try std.fs.cwd().openFile(path, .{});
                    const stat = try file.stat();
                    const offset = stat.size;
                    try runtime.fs.write(&file, batch_fn, file.handle, try out.toOwnedSlice(), offset);
                }
            }.init, {}, struct {
                fn deinit(_: *Runtime, _: void) !void {}
            }.deinit);
        }
    };
}
