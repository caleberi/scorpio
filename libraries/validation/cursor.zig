pub fn Cursor(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: usize,

        const Self = @This();

        pub fn init(buffer: []const T) Self {
            return .{ .buffer = buffer, .index = 0 };
        }

        pub fn current(self: Self) ?T {
            if (self.index < self.buffer.len) {
                return self.buffer[self.index];
            }
            return null;
        }

        pub fn advance(self: *Self) ?T {
            if (self.index >= self.buffer.len) {
                return null;
            }
            const curr = self.buffer[self.index];
            self.index += 1;
            return curr;
        }

        pub fn next(self: *Self) ?T {
            if (self.index < self.buffer.len) {
                const curr = self.buffer[self.index];
                self.index += 1;
                return curr;
            }
            return null;
        }

        pub fn previous(self: *Self) ?T {
            if (self.index > 0) {
                self.index -= 1;
                return self.buffer[self.index];
            }
            return null;
        }

        pub fn peekForward(self: Self) ?T {
            const next_index = self.index + 1;
            if (next_index < self.buffer.len) {
                return self.buffer[next_index];
            }
            return null;
        }

        pub fn peekBackward(self: Self) ?T {
            if (self.index > 0) {
                return self.buffer[self.index - 1];
            }
            return null;
        }
    };
}
