const zstd = @import("std");

pub fn Box(comptime Ptr: type) type {
    const ptr_info = switch (@typeInfo(Ptr)) {
        .pointer => |info| info,
        else => @compileError("Box expects *T or []T, got " ++ @typeName(Ptr)),
    };
    const Child = ptr_info.child;

    return struct {
        data: Ptr,
        allocator: zstd.mem.Allocator,

        const Self = @This();

        /// Take ownership of an existing heap pointer/slice. Caller must not free it.
        pub fn wrap(allocator: zstd.mem.Allocator, data: Ptr) Self {
            return .{
                .data = data,
                .allocator = allocator,
            };
        }

        fn createOne(allocator: zstd.mem.Allocator) !Self {
            if (ptr_info.size != .one) {
                @compileError("Box(" ++ @typeName(Ptr) ++ ").create takes a length for slices");
            }
            const p = try allocator.create(Child);
            return wrap(allocator, p);
        }

        fn createSlice(allocator: zstd.mem.Allocator, len: usize) !Self {
            if (ptr_info.size != .slice) {
                @compileError("Box(" ++ @typeName(Ptr) ++ ").create does not take a length");
            }
            const s = try allocator.alloc(Child, len);
            return wrap(allocator, s);
        }

        pub const create = switch (ptr_info.size) {
            .one => createOne,
            .slice => createSlice,
            else => @compileError("Box only supports *T and []T, got " ++ @typeName(Ptr)),
        };

        pub fn get(self: *const Self) Ptr {
            return self.data;
        }

        pub fn clean(self: *Self) void {
            switch (ptr_info.size) {
                .one => self.allocator.destroy(self.data),
                .slice => self.allocator.free(self.data),
                else => unreachable,
            }
            self.* = undefined;
        }
    };
}

const testing = zstd.testing;

test Box {
    const Test = struct {
        name: []const u8,
        test_fn: *const fn (allocator: zstd.mem.Allocator) anyerror!void,
    };

    const testcases: []const Test = &.{
        .{
            .name = "create *i32",
            .test_fn = struct {
                fn run(allocator: zstd.mem.Allocator) anyerror!void {
                    var boxed = try Box(*i32).create(allocator);
                    defer boxed.clean();
                    boxed.get().* = 42;
                    try testing.expectEqual(@as(i32, 42), boxed.get().*);
                }
            }.run,
        },
        .{
            .name = "wrap *u8",
            .test_fn = struct {
                fn run(allocator: zstd.mem.Allocator) anyerror!void {
                    const raw = try allocator.create(u8);
                    raw.* = 3;

                    var wrapped = Box(*u8).wrap(allocator, raw);
                    defer wrapped.clean();
                    try testing.expectEqual(@as(u8, 3), wrapped.get().*);
                    try testing.expect(wrapped.get() == raw);
                }
            }.run,
        },
        .{
            .name = "create *[N]T array",
            .test_fn = struct {
                fn run(allocator: zstd.mem.Allocator) anyerror!void {
                    var boxed = try Box(*[4]u8).create(allocator);
                    defer boxed.clean();
                    @memset(boxed.get(), 0xaa);
                    try testing.expectEqual(@as(usize, 4), boxed.get().len);
                    try testing.expectEqual(@as(u8, 0xaa), boxed.get()[2]);
                }
            }.run,
        },
        .{
            .name = "create []T slice",
            .test_fn = struct {
                fn run(allocator: zstd.mem.Allocator) anyerror!void {
                    var boxed = try Box([]u8).create(allocator, 8);
                    defer boxed.clean();
                    @memset(boxed.get(), 1);
                    try testing.expectEqual(@as(usize, 8), boxed.get().len);
                    try testing.expectEqual(@as(u8, 1), boxed.get()[0]);
                }
            }.run,
        },
        .{
            .name = "wrap []T slice",
            .test_fn = struct {
                fn run(allocator: zstd.mem.Allocator) anyerror!void {
                    const raw = try allocator.alloc(u16, 3);
                    @memset(raw, 9);

                    var wrapped = Box([]u16).wrap(allocator, raw);
                    defer wrapped.clean();
                    try testing.expectEqual(@as(usize, 3), wrapped.get().len);
                    try testing.expectEqual(@as(u16, 9), wrapped.get()[1]);
                    try testing.expect(wrapped.get().ptr == raw.ptr);
                }
            }.run,
        },
    };

    const allocator = testing.allocator;
    for (testcases) |testcase| {
        try testcase.test_fn(allocator);
    }
}
