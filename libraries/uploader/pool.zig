const zstd = @import("std");
const primitives = @import("primitives");
const cloudinary = @import("cloudinary.zig");

const Channel = primitives.Channel;
const WaitGroup = primitives.WaitGroup;
const Cloudinary = cloudinary.Cloudinary;
const ResourceType = cloudinary.ResourceType;

const max_workers: usize = 4;

pub const Job = struct {
    id: usize,
    path: []const u8,
    public_id: []const u8,
    resource_type: ResourceType = .raw,
    tags: ?[]const u8 = null,
    overwrite: bool = true,
    invalidate: bool = true,
    label: []const u8 = &.{},
};

pub const Result = struct {
    id: usize,
    ok: bool,
    public_id: []const u8 = &.{},
    url: []const u8 = &.{},
    bytes: u64 = 0,
    version: u64 = 0,
};

pub const Outcome = struct {
    allocator: zstd.mem.Allocator,
    results: []Result,

    pub fn deinit(self: *Outcome) void {
        for (self.results) |r| {
            if (r.public_id.len != 0) self.allocator.free(r.public_id);
            if (r.url.len != 0) self.allocator.free(r.url);
        }
        self.allocator.free(self.results);
        self.* = undefined;
    }
};

const WorkerCtx = struct {
    jobs: *Channel(Job),
    results: *Channel(Result),
    allocator: zstd.mem.Allocator,
    cloud_name: []const u8,
    api_key: []const u8,
    api_secret: []const u8,
};

/// Upload each job with the shared client, or with a Channel/WaitGroup pool when
/// `io.concurrent` is available and there is more than one job. Result strings
/// are copied onto `allocator` before any worker client is deinited.
pub fn run(
    allocator: zstd.mem.Allocator,
    io: zstd.Io,
    cloud: *Cloudinary,
    jobs: []const Job,
) !Outcome {
    if (jobs.len == 0) {
        return .{ .allocator = allocator, .results = try allocator.alloc(Result, 0) };
    }
    if (jobs.len == 1) return runSequential(allocator, cloud, jobs);

    const job_buf = try allocator.alloc(Job, jobs.len);
    defer allocator.free(job_buf);
    const result_buf = try allocator.alloc(Result, jobs.len);
    defer allocator.free(result_buf);

    var job_ch = Channel(Job).initBuffered(job_buf);
    var result_ch = Channel(Result).initBuffered(result_buf);

    var ctx = WorkerCtx{
        .jobs = &job_ch,
        .results = &result_ch,
        .allocator = allocator,
        .cloud_name = cloud.cloud_name,
        .api_key = cloud.api_key,
        .api_secret = cloud.api_secret,
    };

    var wg = WaitGroup.init(io);
    var active = false;
    errdefer if (active) {
        wg.cancel();
        wg.join() catch {};
    };

    const workers = @min(max_workers, jobs.len);
    var spawned: usize = 0;
    while (spawned < workers) {
        wg.zig(worker, .{ io, &ctx }) catch {
            wg.cancel();
            wg.join() catch {};
            active = false;
            return runSequential(allocator, cloud, jobs);
        };
        active = true;
        spawned += 1;
    }

    for (jobs) |job| {
        try job_ch.trySend(io, job);
    }
    try job_ch.close(io);

    const results = try allocator.alloc(Result, jobs.len);
    var got: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < got) : (i += 1) {
            if (results[i].public_id.len != 0) allocator.free(results[i].public_id);
            if (results[i].url.len != 0) allocator.free(results[i].url);
        }
        allocator.free(results);
    }

    while (got < jobs.len) {
        results[got] = result_ch.receive(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return error.Closed,
        };
        got += 1;
    }

    result_ch.close(io) catch {};
    wg.join() catch {};
    active = false;

    return .{ .allocator = allocator, .results = results };
}

fn runSequential(allocator: zstd.mem.Allocator, cloud: *Cloudinary, jobs: []const Job) !Outcome {
    const results = try allocator.alloc(Result, jobs.len);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) {
            if (results[i].public_id.len != 0) allocator.free(results[i].public_id);
            if (results[i].url.len != 0) allocator.free(results[i].url);
        }
        allocator.free(results);
    }
    for (jobs, 0..) |job, i| {
        results[i] = uploadOne(allocator, cloud, job);
        filled = i + 1;
    }
    return .{ .allocator = allocator, .results = results };
}

fn worker(io: zstd.Io, ctx: *WorkerCtx) zstd.Io.Cancelable!void {
    var client = Cloudinary.init(
        ctx.allocator,
        io,
        ctx.cloud_name,
        ctx.api_key,
        ctx.api_secret,
    );
    defer client.deinit();

    while (true) {
        const job = ctx.jobs.receive(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
        const result = uploadOne(ctx.allocator, &client, job);
        ctx.results.send(io, result) catch |err| switch (err) {
            error.Canceled => {
                if (result.public_id.len != 0) ctx.allocator.free(result.public_id);
                if (result.url.len != 0) ctx.allocator.free(result.url);
                return error.Canceled;
            },
            error.Closed => {
                if (result.public_id.len != 0) ctx.allocator.free(result.public_id);
                if (result.url.len != 0) ctx.allocator.free(result.url);
                return;
            },
        };
    }
}

fn uploadOne(allocator: zstd.mem.Allocator, cloud: *Cloudinary, job: Job) Result {
    const label = if (job.label.len != 0) job.label else job.path;
    zstd.log.info("uploading {s}", .{label});

    var parsed = cloud.uploadFile(job.path, .{
        .resource_type = job.resource_type,
        .public_id = job.public_id,
        .overwrite = job.overwrite,
        .invalidate = job.invalidate,
        .tags = job.tags,
    }) catch |err| {
        zstd.log.warn("upload skipped for {s}: {}", .{ label, err });
        return .{ .id = job.id, .ok = false };
    };
    defer parsed.deinit();

    const pid_src = if (parsed.value.public_id.len != 0) parsed.value.public_id else job.public_id;
    const public_id = allocator.dupe(u8, pid_src) catch {
        zstd.log.warn("upload skipped for {s}: {}", .{ label, error.OutOfMemory });
        return .{ .id = job.id, .ok = false };
    };
    const url = copyDeliveryUrl(allocator, cloud, parsed.value, public_id, job.resource_type) catch |err| {
        allocator.free(public_id);
        zstd.log.warn("upload skipped for {s}: {}", .{ label, err });
        return .{ .id = job.id, .ok = false };
    };

    return .{
        .id = job.id,
        .ok = true,
        .public_id = public_id,
        .url = url,
        .bytes = parsed.value.bytes,
        .version = parsed.value.version,
    };
}

fn copyDeliveryUrl(
    allocator: zstd.mem.Allocator,
    cloud: *Cloudinary,
    res: cloudinary.Resource,
    public_id: []const u8,
    resource_type: ResourceType,
) ![]u8 {
    if (res.secure_url.len > 0) return allocator.dupe(u8, res.secure_url);
    if (res.url.len > 0) return allocator.dupe(u8, res.url);
    return cloud.deliveryUrl(allocator, public_id, resource_type, .upload);
}
