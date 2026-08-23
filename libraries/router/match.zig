const std = @import("std");
const zap = @import("zap");
const testing = std.testing;
pub const Method = zap.http.Method;

pub const Value = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    array: []const Value,

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .int, .float => {},
            .string => |s| allocator.free(s),
            .array => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
        }
    }

    /// Parse a single path segment into the tightest matching variant.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Value {
        if (std.fmt.parseInt(i64, text, 10)) |i| {
            return .{ .int = i };
        } else |_| {}

        if (looksLikeFloat(text)) {
            if (std.fmt.parseFloat(f64, text)) |f| {
                return .{ .float = f };
            } else |_| {}
        }

        return .{ .string = try allocator.dupe(u8, text) };
    }

    pub fn fromSegments(allocator: std.mem.Allocator, segs: []const []const u8) !Value {
        const items = try allocator.alloc(Value, segs.len);
        var filled: usize = 0;
        errdefer {
            for (items[0..filled]) |item| item.deinit(allocator);
            allocator.free(items);
        }
        for (segs, 0..) |seg, i| {
            items[i] = try parse(allocator, seg);
            filled += 1;
        }
        return .{ .array = items };
    }

    pub fn toString(self: Value, allocator: std.mem.Allocator) ![]u8 {
        switch (self) {
            .int => |i| return std.fmt.allocPrint(allocator, "{d}", .{i}),
            .float => |f| return std.fmt.allocPrint(allocator, "{d}", .{f}),
            .string => |s| return allocator.dupe(u8, s),
            .array => |items| {
                var list: std.ArrayList(u8) = .empty;
                errdefer list.deinit(allocator);
                for (items, 0..) |item, i| {
                    if (i > 0) try list.append(allocator, '/');
                    const piece = try item.toString(allocator);
                    defer allocator.free(piece);
                    try list.appendSlice(allocator, piece);
                }
                return try list.toOwnedSlice(allocator);
            },
        }
    }
};

pub const PathParams = std.StringHashMapUnmanaged(Value);

fn looksLikeFloat(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '.') != null or
        std.mem.indexOfScalar(u8, text, 'e') != null or
        std.mem.indexOfScalar(u8, text, 'E') != null;
}

pub fn methodFromRequest(method: ?[]const u8) Method {
    return zap.http.methodToEnum(method);
}

/// Match `path` against `pattern` (`/users/:id`, `/blog/*slug`, `/blog/*slug/comments`).
/// On success, fills `params` with owned path-parameter values
/// (caller frees via `freePathParams`).
///
/// A splat param (`*name`) captures one or more path segments as `.array`.
/// If the pattern continues after the splat, those trailing segments are matched
/// from the end of the remaining path (e.g. `/blog/*slug/comments`).
pub fn matchPath(allocator: std.mem.Allocator, pattern: []const u8, path: []const u8, params: *PathParams) !bool {
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
                    try putParam(allocator, params, pname, seg);
                } else if (after_pat.len > 0 and after_pat[0] == '*') {
                    // Nested splats after a splat are not supported.
                    clearPathParams(allocator, params);
                    return false;
                } else if (!std.mem.eql(u8, after_pat, seg)) {
                    clearPathParams(allocator, params);
                    return false;
                }
            }

            const rest = try Value.fromSegments(allocator, remaining.items[0..splat_end]);
            errdefer rest.deinit(allocator);
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
            try putParam(allocator, params, name, seg.?);
        } else if (!std.mem.eql(u8, pat.?, seg.?)) {
            clearPathParams(allocator, params);
            return false;
        }
    }
}

fn putParam(allocator: std.mem.Allocator, params: *PathParams, name: []const u8, text: []const u8) !void {
    const value = try Value.parse(allocator, text);
    errdefer value.deinit(allocator);
    try params.put(allocator, name, value);
}

pub fn freePathParams(allocator: std.mem.Allocator, params: *PathParams) void {
    clearPathParams(allocator, params);
    params.deinit(allocator);
}

fn clearPathParams(allocator: std.mem.Allocator, params: *PathParams) void {
    var it = params.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
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
    try testing.expectEqual(@as(i64, 42), params.get("id").?.int);
    try testing.expect(try matchPath(testing.allocator, "/users/:id/posts/:postId", "/users/7/posts/9", &params));
    try testing.expectEqual(@as(i64, 7), params.get("id").?.int);
    try testing.expectEqual(@as(i64, 9), params.get("postId").?.int);
}

test "match float path params" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);
    try testing.expect(try matchPath(testing.allocator, "/n/:x", "/n/3.14", &params));
    try testing.expectEqual(@as(f64, 3.14), params.get("x").?.float);
}

test "match splat path params" {
    var params: PathParams = .{};
    defer freePathParams(testing.allocator, &params);

    try testing.expect(try matchPath(testing.allocator, "/blog/*slug", "/blog/sample", &params));
    try testing.expectEqual(@as(usize, 1), params.get("slug").?.array.len);
    try testing.expectEqualStrings("sample", params.get("slug").?.array[0].string);

    try testing.expect(try matchPath(testing.allocator, "/blog/*slug", "/blog/guides/foo", &params));
    try testing.expectEqual(@as(usize, 2), params.get("slug").?.array.len);
    try testing.expectEqualStrings("guides", params.get("slug").?.array[0].string);
    try testing.expectEqualStrings("foo", params.get("slug").?.array[1].string);

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
    try testing.expectEqual(@as(usize, 2), params.get("slug").?.array.len);
    try testing.expectEqualStrings("guides", params.get("slug").?.array[0].string);
    try testing.expectEqualStrings("intro", params.get("slug").?.array[1].string);

    try testing.expect(try matchPath(
        testing.allocator,
        "/blog/*slug/comments/:comment_id/replies/:reply_id",
        "/blog/a/b/comments/c1/replies/r1",
        &params,
    ));
    try testing.expectEqual(@as(usize, 2), params.get("slug").?.array.len);
    try testing.expectEqualStrings("a", params.get("slug").?.array[0].string);
    try testing.expectEqualStrings("b", params.get("slug").?.array[1].string);
    try testing.expectEqualStrings("c1", params.get("comment_id").?.string);
    try testing.expectEqualStrings("r1", params.get("reply_id").?.string);

    try testing.expect(!try matchPath(
        testing.allocator,
        "/blog/*slug/comments",
        "/blog/comments",
        &params,
    ));
}
