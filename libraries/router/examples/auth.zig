const zstd = @import("std");
const zap = @import("zap");
const bind = @import("../bind.zig");

const Allocator = zstd.mem.Allocator;
const Sha256 = zstd.crypto.hash.sha2.Sha256;
const testing = zstd.testing;

pub const AuthMiddleware = struct {
    pub fn handle(
        _: Allocator,
        request: zap.Request,
        _: *bind.RequestContext,
    ) !bool {
        const provided = request.getHeader("api_key") orelse {
            try reject(request);
            return false;
        };
        const expected = expectedKey() orelse {
            try reject(request);
            return false;
        };
        if (!keysMatch(provided, expected)) {
            try reject(request);
            return false;
        }
        return true;
    }
};

fn expectedKey() ?[]const u8 {
    const value = zstd.c.getenv("API_KEY") orelse return null;
    const slice = zstd.mem.span(value);
    return if (slice.len == 0) null else slice;
}

fn keysMatch(provided: []const u8, expected: []const u8) bool {
    var provided_hash: [Sha256.digest_length]u8 = undefined;
    var expected_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(provided, &provided_hash, .{});
    Sha256.hash(expected, &expected_hash, .{});
    return zstd.crypto.timing_safe.eql(
        [Sha256.digest_length]u8,
        provided_hash,
        expected_hash,
    );
}

fn reject(request: zap.Request) !void {
    request.setStatus(.unauthorized);
    try request.sendJson("{\"error_message\":\"unauthorized\"}");
}

test "auth keysMatch accepts equal keys" {
    try testing.expect(keysMatch("secret", "secret"));
}

test "auth keysMatch rejects different keys" {
    try testing.expect(!keysMatch("secret", "other"));
}

test "auth keysMatch rejects different lengths" {
    try testing.expect(!keysMatch("short", "much-longer-key"));
}
