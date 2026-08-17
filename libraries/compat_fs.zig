const std = @import("std");
const posix = std.posix;
const c = std.c;

pub const path = std.fs.path;

const libc = struct {
    const close = @extern(*const fn (c.fd_t) callconv(.c) c_int, .{ .name = "close" });
    const fstat = @extern(*const fn (c.fd_t, *c.Stat) callconv(.c) c_int, .{ .name = "fstat" });
    const write = @extern(*const fn (c.fd_t, [*]const u8, usize) callconv(.c) isize, .{ .name = "write" });
    const read = @extern(*const fn (c.fd_t, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
    const openat = @extern(*const fn (c.fd_t, [*:0]const u8, c_int, c.mode_t) callconv(.c) c_int, .{ .name = "openat" });
    const mkdirat = @extern(*const fn (c.fd_t, [*:0]const u8, c.mode_t) callconv(.c) c_int, .{ .name = "mkdirat" });
    const unlinkat = @extern(*const fn (c.fd_t, [*:0]const u8, c_uint) callconv(.c) c_int, .{ .name = "unlinkat" });
    const dup = @extern(*const fn (c.fd_t) callconv(.c) c_int, .{ .name = "dup" });
    const realpath = @extern(*const fn ([*:0]const u8, ?[*]u8) callconv(.c) ?[*:0]u8, .{ .name = "realpath" });
};

pub const Stat = struct {
    size: u64,
    mode: c.mode_t,
    mtime: i128,
    atime: i128,
    ctime: i128,
};

fn timespecToNanos(ts: c.timespec) i128 {
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn check(rc: anytype) !@TypeOf(rc) {
    if (rc >= 0) return rc;
    return switch (std.c._errno().*) {
        @intFromEnum(std.c.E.NOENT) => error.FileNotFound,
        @intFromEnum(std.c.E.EXIST) => error.PathAlreadyExists,
        @intFromEnum(std.c.E.ACCES) => error.AccessDenied,
        @intFromEnum(std.c.E.ISDIR) => error.IsDir,
        @intFromEnum(std.c.E.NOTDIR) => error.NotDir,
        else => error.Unexpected,
    };
}

fn statFromC(st: c.Stat) Stat {
    return .{
        .size = @intCast(st.size),
        .mode = st.mode,
        .mtime = timespecToNanos(st.mtime()),
        .atime = timespecToNanos(st.atime()),
        .ctime = timespecToNanos(st.ctime()),
    };
}

// Darwin open flags (also valid enough for Linux for these bits we use).
const O_RDONLY: c_int = 0x0000;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = if (@import("builtin").os.tag == .macos) 0x0200 else 0x40;
const O_TRUNC: c_int = if (@import("builtin").os.tag == .macos) 0x0400 else 0x200;
const O_EXCL: c_int = if (@import("builtin").os.tag == .macos) 0x0800 else 0x80;
const O_DIRECTORY: c_int = if (@import("builtin").os.tag == .macos) 0x100000 else 0x10000;

pub const File = struct {
    handle: c.fd_t,

    pub fn close(self: File) void {
        _ = libc.close(self.handle);
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const n = try check(libc.write(self.handle, bytes[written..].ptr, bytes.len - written));
            if (n == 0) return error.Unexpected;
            written += @intCast(n);
        }
    }

    pub fn stat(self: File) !Stat {
        var st: c.Stat = undefined;
        _ = try check(libc.fstat(self.handle, &st));
        return statFromC(st);
    }
};

pub const Dir = struct {
    fd: c.fd_t,
    owns_fd: bool = true,

    pub fn close(self: *Dir) void {
        if (self.owns_fd and self.fd != posix.AT.FDCWD) {
            _ = libc.close(self.fd);
        }
        self.* = undefined;
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenDirOptions) !Dir {
        _ = options;
        const z = try std.heap.page_allocator.dupeZ(u8, sub_path);
        defer std.heap.page_allocator.free(z);
        const fd = try check(libc.openat(self.fd, z.ptr, O_RDONLY | O_DIRECTORY, 0));
        return .{ .fd = fd, .owns_fd = true };
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        if (sub_path.len == 0) return;
        var iterator = std.mem.tokenizeAny(u8, sub_path, "/");

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(std.heap.page_allocator);

        var first = true;
        while (iterator.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (!first) try prefix.append(std.heap.page_allocator, '/');
            first = false;
            try prefix.appendSlice(std.heap.page_allocator, part);
            const z = try std.heap.page_allocator.dupeZ(u8, prefix.items);
            defer std.heap.page_allocator.free(z);
            if (libc.mkdirat(self.fd, z.ptr, 0o755) < 0) {
                // Already exists is fine; otherwise verify we can open it as a dir.
                var probe = self.openDir(prefix.items, .{}) catch return error.Unexpected;
                probe.close();
            }
        }
    }

    pub fn createFile(self: Dir, sub_path: []const u8, options: CreateFileOptions) !File {
        var flags: posix.O = .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
        };
        if (options.truncate) flags.TRUNC = true;
        if (options.exclusive) flags.EXCL = true;
        const fd = try posix.openat(
            self.fd,
            sub_path,
            flags,
            options.mode,
        );
        return .{ .handle = fd };
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenFileOptions) !File {
        _ = options;
        const fd = try posix.openat(
            self.fd,
            sub_path,
            .{ .ACCMODE = .RDONLY },
            0,
        );
        return .{ .handle = fd };
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        const z = try std.heap.page_allocator.dupeZ(u8, sub_path);
        defer std.heap.page_allocator.free(z);
        _ = try check(libc.unlinkat(self.fd, z.ptr, 0));
    }

    pub fn stat(self: Dir) !Stat {
        var st: c.Stat = undefined;
        _ = try check(libc.fstat(self.fd, &st));
        return statFromC(st);
    }

    pub fn statFile(self: Dir, sub_path: []const u8) !Stat {
        const file = try self.openFile(sub_path, .{});
        defer file.close();
        return file.stat();
    }

    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) ![]u8 {
        const file = try self.openFile(sub_path, .{});
        defer file.close();

        const st = try file.stat();
        if (st.size > max_bytes) return error.FileTooBig;

        const buf = try allocator.alloc(u8, @intCast(st.size));
        errdefer allocator.free(buf);

        var total: usize = 0;
        while (total < buf.len) {
            const n = try check(libc.read(file.handle, buf[total..].ptr, buf.len - total));
            if (n == 0) break;
            total += @intCast(n);
        }
        if (total != buf.len) return allocator.realloc(buf, total);
        return buf;
    }

    pub fn writeFile(self: Dir, args: struct { sub_path: []const u8, data: []const u8 }) !void {
        if (path.dirname(args.sub_path)) |parent| {
            try self.makePath(parent);
        }
        const file = try self.createFile(args.sub_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(args.data);
    }

    pub fn iterate(self: Dir) !Iterator {
        const duped = try check(libc.dup(self.fd));
        const dirp = c.fdopendir(duped) orelse {
            _ = libc.close(duped);
            return error.Unexpected;
        };
        return .{ .dirp = dirp };
    }

    pub fn walk(self: Dir, allocator: std.mem.Allocator) !Walker {
        return Walker.init(allocator, self);
    }

    pub const Iterator = struct {
        dirp: *c.DIR,

        pub fn next(self: *Iterator) !?Entry {
            while (true) {
                const ent = c.readdir(self.dirp) orelse return null;
                const namelen: usize = if (@hasField(@TypeOf(ent.*), "namlen")) ent.namlen else std.mem.len(@as([*:0]const u8, @ptrCast(&ent.name)));
                const name = ent.name[0..namelen];
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const dtype = if (@hasField(@TypeOf(ent.*), "type")) ent.type else ent.d_type;
                const kind: Entry.Kind = switch (dtype) {
                    c.DT.DIR => .directory,
                    c.DT.REG => .file,
                    c.DT.LNK => .sym_link,
                    else => .unknown,
                };
                return .{ .name = name, .kind = kind };
            }
        }

        pub fn deinit(self: *Iterator) void {
            _ = c.closedir(self.dirp);
            self.* = undefined;
        }
    };

    pub const Entry = struct {
        name: []const u8,
        kind: Kind,
        pub const Kind = enum { file, directory, sym_link, unknown };
    };
};

pub const Walker = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Frame),
    name_buffer: std.ArrayList(u8),

    const Frame = struct {
        dir: Dir,
        iter: Dir.Iterator,
        dirname_len: usize,
    };

    pub const Entry = struct {
        dir: Dir,
        basename: []const u8,
        path: []const u8,
        kind: Dir.Entry.Kind,
    };

    pub fn init(allocator: std.mem.Allocator, root: Dir) !Walker {
        var stack: std.ArrayList(Frame) = .empty;
        errdefer {
            while (stack.pop()) |frame_const| {
                var frame = frame_const;
                frame.iter.deinit();
                frame.dir.close();
            }
            stack.deinit(allocator);
        }

        const owned_fd = try check(libc.dup(root.fd));
        const owned = Dir{ .fd = owned_fd, .owns_fd = true };
        var iter = try owned.iterate();
        errdefer {
            iter.deinit();
            var d = owned;
            d.close();
        }

        try stack.append(allocator, .{
            .dir = owned,
            .iter = iter,
            .dirname_len = 0,
        });

        return .{
            .allocator = allocator,
            .stack = stack,
            .name_buffer = .empty,
        };
    }

    pub fn deinit(self: *Walker) void {
        while (self.stack.pop()) |frame_const| {
            var frame = frame_const;
            frame.iter.deinit();
            frame.dir.close();
        }
        self.stack.deinit(self.allocator);
        self.name_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *Walker) !?Entry {
        while (self.stack.items.len > 0) {
            const top = &self.stack.items[self.stack.items.len - 1];
            if (try top.iter.next()) |entry| {
                self.name_buffer.shrinkRetainingCapacity(top.dirname_len);
                if (self.name_buffer.items.len > 0) {
                    try self.name_buffer.append(self.allocator, '/');
                }
                try self.name_buffer.appendSlice(self.allocator, entry.name);

                if (entry.kind == .directory) {
                    var child = try top.dir.openDir(entry.name, .{ .iterate = true });
                    errdefer child.close();
                    var child_iter = try child.iterate();
                    errdefer child_iter.deinit();
                    try self.stack.append(self.allocator, .{
                        .dir = child,
                        .iter = child_iter,
                        .dirname_len = self.name_buffer.items.len,
                    });
                }

                return .{
                    .dir = top.dir,
                    .basename = entry.name,
                    .path = self.name_buffer.items,
                    .kind = entry.kind,
                };
            }

            var finished = self.stack.pop().?;
            finished.iter.deinit();
            finished.dir.close();
        }
        return null;
    }
};

pub const OpenDirOptions = struct {
    access_sub_paths: bool = true,
    iterate: bool = false,
};

pub const OpenFileOptions = struct {};

pub const CreateFileOptions = struct {
    truncate: bool = true,
    exclusive: bool = false,
    mode: c.mode_t = 0o666,
};

pub fn cwd() Dir {
    return .{ .fd = posix.AT.FDCWD, .owns_fd = false };
}

pub fn openDirAbsolute(absolute_path: []const u8, options: OpenDirOptions) !Dir {
    return cwd().openDir(absolute_path, options);
}

pub fn realpathAlloc(allocator: std.mem.Allocator, pathname: []const u8) ![]u8 {
    const z = try allocator.dupeZ(u8, pathname);
    defer allocator.free(z);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = libc.realpath(z.ptr, &buf) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(result));
}
