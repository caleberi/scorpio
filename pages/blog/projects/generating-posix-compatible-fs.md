---
title: 'Generating POSIX-compatible filesystems in Zig using AI'
summary: 'Binding libc file operations in Zig with @extern, wrapping them in a File type, and using AI without trusting it blindly'
authors:
  - 'Adewole Caleb'
date: '2026-08-17'
topics:
  - 'Zig'
  - 'Engineering'
  - 'Filesystems'
  - 'Posix'
  - 'AI'
type: 'Blog'
image: '![image](../../../blobs/cover7.webp)'
---

I've been working on this project with Zig and AI so I can learn how to solve problems using my engineering knowledge together with agentic programming.

One thing I have done so far is build my own packed blog: mostly an in-memory database in RAM, with a little disk storage via Postgres. The point is a fully functional blog I can drop on any server using only packed posts, images, and other media.

That packing path is full of file work. Zig lets you call C functions via `extern`, so a small module that talks POSIX felt like a good idea. Last time I used Zig 0.15 I could call `std.posix` directly, but fuck it I want to try something new.

## Translating a C POSIX function to Zig

Start from the man page, then put the C signatures into a namespace struct that calls the linked C library.

```bash
man openat

OPEN(2)                           System Calls Manual                          OPEN(2)

NAME
     open, openat – open or create a file for reading or writing

SYNOPSIS
     #include <fcntl.h>

     int
     open(const char *path, int oflag, ...);

     int
     openat(int fd, const char *path, int oflag, ...);

....
```

Same function in Zig, sitting in a `libc` namespace with the rest of the conversions:

```zig
const libc = struct {
    const openat = @extern(*const fn (c_int, [*:0]const u8, c_int, ...) callconv(.c) c_int, .{ .name = "openat" });
};

// function == *const fn(args...) callconv(.c) return_type
// C int maps to c_int
// C string maps to [*:0]const u8
// ... maps to varargs
```

The mapping is mechanical. Once you know the signature and the types, you can ask the model to generate the binding and actually check what it wrote. Varargs is the C signature; in practice I pin the mode argument so Zig can type-check it.

From there, pull more of the man page into the same namespace:

```zig
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
```

The calls still return C types, so those get mapped too. `c.Stat` becomes a small Zig `Stat`:

```zig
const Stat = struct {
    size: u64,
    mode: c.mode_t,
    mtime: i128,
    atime: i128,
    ctime: i128,
};

fn timespecToNanos(ts: c.timespec) i128 {
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
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
```

`timespecToNanos` turns a `timespec` into nanoseconds since the epoch. `statFromC` copies the C stat into that Zig struct.

POSIX returns negative on error, so a small `check` helper turns that into a Zig error before anything else uses the result. With that in place, wrap the file descriptor in a `File` type so the rest of the project talks Zig instead of raw `int fd`:

```zig
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
```

Same `int fd` a C program would hold, just with methods on it. A `Dir` wrapper for directory descriptors follows the same pattern. I won't go into that here.

## Using the File struct

Once you have a `File`, the rest looks like Zig:

```zig
const file = try File.open("test.txt", .{ .create = true });
defer file.close();
try file.writeAll("hello");
const st = try file.stat();
```

Zig is not mature enough yet, so things are a bit tricky to work with. Using AI to generate the bindings is a good idea, but you have to be careful: the code might not be correct or safe. Every line should be verified by you or a trusted source.

Typically I would read generated code more carefully before committing it to the project.
