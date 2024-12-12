const std = @import("std");

pub fn ManagedPointer(comptime T: type) type {
    return struct {
        data: *T,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn wrap(allocator: std.mem.Allocator, data: *T) Self {
            return .{
                .data = data,
                .allocator = allocator,
            };
        }

        pub fn clean(self: *Self) void {
            switch (@typeInfo(self.data)) {
                .Pointer => |v| {
                    const p = v.size;
                    switch (p) {
                        .Many => self.allocator.free(self.data),
                        .One => self.allocator.destroy(self.data),
                    }
                },
                _ => return,
            }
        }
    };
}
