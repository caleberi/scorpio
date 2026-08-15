const std = @import("std");
const zap = @import("zap");
const testing = std.testing;

pub const Method = zap.http.Method;
pub const PathParams = std.StringHashMapUnmanaged([]const u8);

pub fn methodFromRequest(method: ?[]const u8) Method {
    return zap.http.methodToEnum(method);
}

/// Match `path` against `pattern` (`/users/:id`, `/blog/*slug`, `/blog/*slug/comments`).
/// On success, fills `params` with owned path-parameter values
/// (caller frees via `freePathParams`).
///
/// A splat param (`*name`) captures one or more path segments. If the pattern
/// continues after the splat, those trailing segments are matched from the end
/// of the remaining path (e.g. `/blog/*slug/comments` → slug = `guides/intro`).
pub fn matchPath(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    params: *PathParams,
) !bool {
    clearPathParams(allocator, params);

    var pattern_parts = std.mem.splitScalar(u8, trimSlashes(pattern), '/');
    var path_parts = std.mem.splitScalar(u8, trimSlashes(path), '/');

    while (true) {
        const pat = pattern_parts.next();

        if (pat == null) {
            if (path_parts.next() == null) return true;
            clearPathParams(allocator, params);
            return false;
        }

        if (pat.?.len > 0 and pat.?[0] == '*') {
            const name = pat.?[1..];
            if (name.len == 0) {
                clearPathParams(allocator, params);
                return false;
            }

            var after_patterns: std.ArrayList([]const u8) = .empty;
            defer after_patterns.deinit(allocator);
            while (pattern_parts.next()) |p| {
                try after_patterns.append(allocator, p);
            }

            var remaining: std.ArrayList([]const u8) = .empty;
            defer remaining.deinit(allocator);
            while (path_parts.next()) |seg| {
                try remaining.append(allocator, seg);
            }

            if (remaining.items.len <= after_patterns.items.len) {
                clearPathParams(allocator, params);
                return false;
            }

            const splat_end = remaining.items.len - after_patterns.items.len;
            if (splat_end == 0) {
                clearPathParams(allocator, params);
                return false;
            }

            for (after_patterns.items, 0..) |after_pat, i| {
                const seg = remaining.items[splat_end + i];
                if (after_pat.len > 0 and after_pat[0] == ':') {
                    const pname = after_pat[1..];
                    if (pname.len == 0) {
                        clearPathParams(allocator, params);
                        return false;
                    }
                    const value = try allocator.dupe(u8, seg);
                    errdefer allocator.free(value);
                    try params.put(allocator, pname, value);
                } else if (after_pat.len > 0 and after_pat[0] == '*') {
                    // Nested splats after a splat are not supported.
                    clearPathParams(allocator, params);
                    return false;
                } else if (!std.mem.eql(u8, after_pat, seg)) {
                    clearPathParams(allocator, params);
                    return false;
                }
            }

            const rest = try joinSegments(allocator, remaining.items[0..splat_end]);
            errdefer allocator.free(rest);
            try params.put(allocator, name, rest);
            return true;
        }

        const seg = path_parts.next();
        if (seg == null) {
            clearPathParams(allocator, params);
            return false;
        }

        if (pat.?.len > 0 and pat.?[0] == ':') {
            const name = pat.?[1..];
            if (name.len == 0) {
                clearPathParams(allocator, params);
                return false;
            }
            const value = try allocator.dupe(u8, seg.?);
            errdefer allocator.free(value);
            try params.put(allocator, name, value);
        } else if (!std.mem.eql(u8, pat.?, seg.?)) {
            clearPathParams(allocator, params);
            return false;
        }
    }
}

fn joinSegments(allocator: std.mem.Allocator, segs: []const []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    for (segs, 0..) |seg, i| {
        if (i > 0) try list.append(allocator, '/');
        try list.appendSlice(allocator, seg);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn freePathParams(allocator: std.mem.Allocator, params: *PathParams) void {
    clearPathParams(allocator, params);
    params.deinit(allocator);
}

fn clearPathParams(allocator: std.mem.Allocator, params: *PathParams) void {
    var it = params.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    params.clearRetainingCapacity();
}

fn trimSlashes(path: []const u8) []const u8 {
    var start: usize = 0;
    var end = path.len;
    while (start < end and path[start] == '/') start += 1;
    while (end > start and path[end - 1] == '/') end -= 1;
    return path[start..end];
}

test "match exact path" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);
    try testing.expect(try matchPath(testing.allocator, "/hello", "/hello", &params));
    try testing.expect(try matchPath(testing.allocator, "/hello", "hello", &params));
    try testing.expect(!try matchPath(testing.allocator, "/hello", "/hello/world", &params));
}

test "match path params" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);
    try testing.expect(try matchPath(testing.allocator, "/users/:id", "/users/42", &params));
    try testing.expectEqualStrings("42", params.get("id").?);
    try testing.expect(try matchPath(testing.allocator, "/users/:id/posts/:postId", "/users/7/posts/9", &params));
    try testing.expectEqualStrings("7", params.get("id").?);
    try testing.expectEqualStrings("9", params.get("postId").?);
}

test "match splat path params" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);

    try testing.expect(try matchPath(testing.allocator, "/blog/*slug", "/blog/sample", &params));
    try testing.expectEqualStrings("sample", params.get("slug").?);

    try testing.expect(try matchPath(testing.allocator, "/blog/*slug", "/blog/guides/foo", &params));
    try testing.expectEqualStrings("guides/foo", params.get("slug").?);

    try testing.expect(!try matchPath(testing.allocator, "/blog/*slug", "/blog", &params));
    try testing.expect(!try matchPath(testing.allocator, "/blog/*slug", "/other/x", &params));
}

test "match splat with trailing segments" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);

    try testing.expect(try matchPath(
        testing.allocator,
        "/blog/*slug/comments",
        "/blog/guides/intro/comments",
        &params,
    ));
    try testing.expectEqualStrings("guides/intro", params.get("slug").?);

    try testing.expect(try matchPath(
        testing.allocator,
        "/blog/*slug/comments/:comment_id/replies/:reply_id",
        "/blog/a/b/comments/c1/replies/r1",
        &params,
    ));
    try testing.expectEqualStrings("a/b", params.get("slug").?);
    try testing.expectEqualStrings("c1", params.get("comment_id").?);
    try testing.expectEqualStrings("r1", params.get("reply_id").?);

    try testing.expect(!try matchPath(
        testing.allocator,
        "/blog/*slug/comments",
        "/blog/comments",
        &params,
    ));
}
