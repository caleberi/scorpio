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
pub const ddog = std.log.scoped(.batch_writer);

pub const GenericBatchWriter = struct {
    log_file: []const u8,
    write_queue: Queue,
    event_loop: *Tardy,
    allocator: std.mem.Allocator,
    _shutdown: bool = false,
    last_write_time: i128,
    mutex: std.Thread.Mutex = .{},
    init_params: ?*ArgsParams = null,

    const Self = @This();
    const Queue = std.DoublyLinkedList([]u8);

    const FileProvision = struct {
        self: *GenericBatchWriter = undefined,
        data: []u8 = undefined,
        buffer: []const u8 = undefined,
        offset: usize = 0,
        written: usize = 0,
        fd: *std.posix.fd_t = undefined,
    };

    const Node = Queue.Node;
    const ArgsParams = struct {
        data: []u8 = undefined,
        ctx: *GenericBatchWriter = undefined,
    };

    pub fn init(allocator: std.mem.Allocator, file: []const u8) !GenericBatchWriter {
        const tardy = try allocator.create(Tardy);
        tardy.* = try Tardy.init(.{
            .allocator = allocator,
            .threading = .single,
            .size_tasks_max = 1,
            .size_aio_jobs_max = 1,
            .size_aio_reap_max = 1,
        });

        return .{
            .log_file = file,
            .allocator = allocator,
            .write_queue = Queue{},
            .event_loop = tardy,
            .last_write_time = std.time.nanoTimestamp(),
        };
    }

    pub fn shutdown(self: *Self) void {
        self._shutdown = true;
    }

    fn monitor_task(runtime: *Runtime, _: void, ctx: *FileProvision) !void {
        ddog.debug("Starting monitor_task", .{});
        const self = ctx.self;
        self.mutex.lock();
        const node = self.write_queue.popFirst();
        self.mutex.unlock();
        ddog.info("Node: {any}", .{node});
        if (node) |n| {
            const data = n.data;
            defer self.allocator.free(data);
            defer self.allocator.destroy(n);

            const cwd = std.fs.cwd();
            const stat: ?std.fs.File.Stat = std.fs.cwd().statFile(self.log_file) catch null;
            var file: std.fs.File = undefined;

            if (stat == null) {
                file = try cwd.createFile(self.log_file, .{});
            } else {
                file = try cwd.openFile(self.log_file, .{ .mode = .write_only });
            }

            const offset = try file.getEndPos();
            const buffer = try self.allocator.dupe(u8, data);
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
            runtime.allocator.destroy(ctx);
            runtime.stop();
        }
        ddog.debug("delay spawn check_queue_task", .{});
        // Check again in 1 second
        try runtime.spawn_delay(
            void,
            ctx,
            check_queue_task,
            .{
                .nanos = std.time.ns_per_s * 5,
            },
        );
    }

    fn close_task(runtime: *Runtime, _: void, ctx: *FileProvision) anyerror!void {
        ddog.debug("Starting close_task", .{});
        ddog.info("done writing to handle={d}", .{ctx.fd.*});
        runtime.allocator.free(ctx.buffer);
        runtime.allocator.destroy(ctx.fd);
        ddog.info("handling the next request, done with = {s}", .{ctx.buffer});
        try runtime.spawn_delay(void, ctx, monitor_task, .{
            .nanos = std.time.ns_per_s * 5,
        });
        ddog.info("last batch write time = {d}", .{ctx.self.last_write_time});
    }

    fn write_task(runtime: *Runtime, length: i32, ctx: *FileProvision) anyerror!void {
        ddog.debug("Starting write_task", .{});
        defer ctx.self.last_write_time = std.time.nanoTimestamp();
        if (length <= 0) {
            try runtime.fs.close(ctx, close_task, ctx.fd.*);
            return;
        }
        ctx.offset += @intCast(length);
        ctx.written += @intCast(length);

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
        try runtime.fs.close(ctx, close_task, ctx.fd.*);
    }

    pub fn log(self: *Self, entry: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = try self.allocator.create(Node);
        node.*.data = entry;
        self.write_queue.append(node);
        const current_length = self.write_queue.len;
        ddog.info("Queue length after enqueue: {d}", .{current_length});
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
        self.allocator.destroy(self.event_loop);
    }
};
