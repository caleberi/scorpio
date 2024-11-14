const std = @import("std");
const Agent = @import("./agent.zig");
const chroma_logger = @import("chroma");
const Tardy = @import("tardy").Tardy(.auto);
const Runtime = @import("tardy").Runtime;
const Cross = @import("tardy").Cross;

pub const std_options = .{
    .log_level = .debug,
    .logFn = chroma_logger.timeBasedLog,
};
const ddog = std.log.scoped(.batch_writer);

pub fn GenericBatchWriter(comptime T: type) type {
    return struct {
        log_file: []const u8,
        write_queue: *Queue,
        event_loop: *Tardy,
        allocator: std.mem.Allocator,
        _shutdown: bool = false,
        last_write_time: i128,
        mutex: std.Thread.Mutex = .{},
        init_params: ?*ArgsParams = null,

        const Self = @This();
        const Batcher = GenericBatchWriter(T);
        const Queue = std.DoublyLinkedList(T);
        const IDLE_TIMEOUT_NS = 5 * std.time.ns_per_s; // 5 seconds idle timeout

        const FileProvision = struct {
            self: *Batcher = undefined,
            data: ?T = null,
            buffer: []const u8 = undefined,
            offset: usize = 0,
            written: usize = 0,
            fd: *std.posix.fd_t = undefined,
        };

        const Node = Queue.Node;
        const ArgsParams = struct {
            data: T = undefined,
            ctx: *Batcher = undefined,
        };

        pub fn init(allocator: std.mem.Allocator, file: []const u8) !*Batcher {
            const tardy = try allocator.create(Tardy);
            tardy.* = try Tardy.init(.{
                .allocator = allocator,
                .threading = .single,
                .size_tasks_max = 1,
                .size_aio_jobs_max = 1,
                .size_aio_reap_max = 1,
            });

            const batcher = try allocator.create(Batcher);
            const queue = try allocator.create(Queue);
            queue.* = Queue{};
            batcher.* = .{
                .log_file = file,
                .allocator = allocator,
                .write_queue = queue,
                .event_loop = tardy,
                .last_write_time = std.time.nanoTimestamp(),
            };

            return batcher;
        }

        pub fn shutdown(self: *Self) void {
            self._shutdown = true;
        }

        fn monitor_task(runtime: *Runtime, _: void, ctx: *FileProvision) !void {
            ddog.debug("Starting monitor_task", .{});
            const self = ctx.self;
            self.mutex.lock();
            const node = self.write_queue.popFirst();
            const queue_length = self.write_queue.len;
            ddog.info("Address of queue = {p}", .{&self.write_queue});
            self.mutex.unlock();
            ddog.info("Queue length after batch: {d}", .{queue_length});
            if (node) |n| {
                const data = n.data;
                defer self.allocator.destroy(n);
                defer self.last_write_time = std.time.nanoTimestamp();

                var out = std.ArrayList(u8).init(runtime.allocator);
                defer out.deinit();
                try std.json.stringify(data, .{}, out.writer());
                try out.append('\n');

                const cwd = std.fs.cwd();
                const stat: ?std.fs.File.Stat = std.fs.cwd().statFile(self.log_file) catch null;
                var file: std.fs.File = undefined;

                if (stat == null) {
                    file = try cwd.createFile(self.log_file, .{});
                } else {
                    file = try cwd.openFile(self.log_file, .{ .mode = .write_only });
                }

                const offset = try file.getEndPos();
                const buffer = try out.toOwnedSlice();
                const handle = try runtime.allocator.create(std.posix.fd_t);
                handle.* = file.handle;
                const new_ctx = try runtime.allocator.create(FileProvision);
                new_ctx.* = FileProvision{
                    .self = ctx.self,
                    .buffer = buffer,
                    .offset = offset,
                    .fd = handle,
                    .written = 0,
                };
                ctx.self = undefined; //  remove pointer so we can clean old ctx
                runtime.allocator.destroy(ctx);
                try runtime.fs.write(
                    @constCast(new_ctx),
                    write_task,
                    new_ctx.fd.*,
                    new_ctx.buffer,
                    new_ctx.offset,
                );
            } else {
                try runtime.spawn(void, ctx, check_queue_task);
            }
        }

        fn check_queue_task(runtime: *Runtime, _: void, ctx: *FileProvision) !void {
            ddog.debug("Starting check_queue_task", .{});
            ctx.self.mutex.lock();
            const length = ctx.self.write_queue.len;
            ddog.info("Address of queue = {p}", .{&ctx.self.write_queue});
            ctx.self.mutex.unlock();
            ddog.info("Queue length after batch: {d}", .{length});
            if (length > 0) {
                ddog.info("Processing node [X]", .{});
                try runtime.spawn(void, ctx, monitor_task);
                return;
            }

            if (ctx.self._shutdown) {
                ddog.info("Shutting down {s}", .{@typeName(Self)});
                while (!runtime.scheduler.tasks.empty()) {}
                runtime.stop();
            }
            ddog.debug("delay spawn check_queue_task", .{});
            // Check again in 1 second
            try runtime.spawn_delay(
                void,
                ctx,
                check_queue_task,
                .{
                    .nanos = std.time.ns_per_s * 30,
                },
            );
        }

        fn close_task(runtime: *Runtime, _: void, ctx: *FileProvision) anyerror!void {
            ddog.debug("Starting close_task", .{});
            ddog.info("done writing to handle={d}", .{ctx.fd.*});
            runtime.allocator.destroy(ctx.fd);
            ddog.info("handling the next request, done with = {s}", .{ctx.buffer});
            try runtime.spawn_delay(void, ctx, monitor_task, .{
                .nanos = std.time.ns_per_s * 30,
            });
            ddog.info("last batch write time = {d}", .{ctx.self.last_write_time});
        }

        fn write_task(runtime: *Runtime, length: i32, ctx: *FileProvision) anyerror!void {
            ddog.debug("Starting write_task", .{});
            if (length <= 0) {
                try runtime.fs.close(ctx, close_task, ctx.fd.*);
                return;
            }
            ctx.offset += @intCast(length);
            ctx.written += @intCast(length);

            // If we haven't written all the data yet, continue writing
            if (ctx.written < ctx.buffer.len) {
                const remaining = ctx.buffer[ctx.written..];
                try runtime.fs.write(
                    ctx,
                    write_task,
                    ctx.fd.*,
                    remaining,
                    ctx.offset,
                );
                return;
            }

            // All data written, close the file
            try runtime.fs.close(ctx, close_task, ctx.fd.*);
        }

        pub fn batch(self: *Self, entry: T) !void {
            ddog.info("Batching new entry", .{});
            const node = try self.allocator.create(Node);
            node.*.data = entry;

            self.mutex.lock();
            self.write_queue.append(node);
            const current_length = self.write_queue.len;
            ddog.info("Address of queue = {p}", .{&self.write_queue});
            self.mutex.unlock();

            ddog.info("Queue length after batch: {d}", .{current_length});
        }

        pub fn run(self: *Self) !void {
            const argParams = try self.allocator.create(ArgsParams);
            argParams.* = ArgsParams{ .ctx = self };
            self.init_params = argParams;

            try self.event_loop.entry(argParams, struct {
                fn init(runtime: *Runtime, args: *ArgsParams) !void {
                    const file_provision = try runtime.allocator.create(FileProvision);
                    file_provision.self = args.ctx;
                    try runtime.spawn(void, @constCast(file_provision), check_queue_task);
                }
            }.init, {}, struct {
                fn deinit(_: *Runtime, _: void) !void {}
            }.deinit);
        }

        pub fn deinit(self: *Self) void {
            while (self.write_queue.pop()) |node| {
                self.allocator.destroy(node);
            }
            if (self.init_params) |ip| {
                self.allocator.destroy(ip);
            }
            self.event_loop.*.deinit();
            self.allocator.destroy(self.write_queue);
            self.allocator.destroy(self.event_loop);
        }
    };
}
