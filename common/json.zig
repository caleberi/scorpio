const zstd = @import("std");
const json = zstd.json;

pub fn serialize(allocator: zstd.mem.Allocator, value: anytype) ![]u8 {
    return json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn serializePretty(allocator: zstd.mem.Allocator, value: anytype) ![]u8 {
    return json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

pub fn serializeOpts(
    allocator: zstd.mem.Allocator,
    value: anytype,
    options: json.Stringify.Options,
) ![]u8 {
    return json.Stringify.valueAlloc(allocator, value, options);
}

pub fn deserialize(comptime T: type, allocator: zstd.mem.Allocator, text: []const u8) !json.Parsed(T) {
    return json.parseFromSlice(T, allocator, text, .{});
}

pub fn deserializeOpts(
    comptime T: type,
    allocator: zstd.mem.Allocator,
    text: []const u8,
    options: json.ParseOptions,
) !json.Parsed(T) {
    return json.parseFromSlice(T, allocator, text, options);
}

/// Arena-friendly parse (no per-field tracking). Prefer an arena allocator.
pub fn deserializeLeaky(
    comptime T: type,
    allocator: zstd.heap.ArenaAllocator,
    text: []const u8,
) !T {
    return json.parseFromSliceLeaky(T, allocator, text, .{});
}

const testing = zstd.testing;

test "serialize / deserialize like JSON.stringify / JSON.parse" {
    const User = struct {
        name: []const u8,
        age: u32,
        active: bool,
    };

    const original: User = .{
        .name = "caleb",
        .age = 28,
        .active = true,
    };

    const bytes = try serialize(testing.allocator, original);
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings(
        \\{"name":"caleb","age":28,"active":true}
    , bytes);

    var parsed = try deserialize(User, testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqualStrings(original.name, parsed.value.name);
    try testing.expectEqual(original.age, parsed.value.age);
    try testing.expectEqual(original.active, parsed.value.active);
}

test "serializePretty and nested round-trip" {
    const Post = struct {
        title: []const u8,
        tags: []const []const u8,
        meta: struct { views: u64 },
    };

    const original: Post = .{
        .title = "hello",
        .tags = &.{ "zig", "json" },
        .meta = .{ .views = 10 },
    };

    const pretty = try serializePretty(testing.allocator, original);
    defer testing.allocator.free(pretty);
    try testing.expect(zstd.mem.indexOf(u8, pretty, "\n") != null);

    var parsed = try deserialize(Post, testing.allocator, pretty);
    defer parsed.deinit();

    try testing.expectEqualStrings("hello", parsed.value.title);
    try testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try testing.expectEqualStrings("zig", parsed.value.tags[0]);
    try testing.expectEqual(@as(u64, 10), parsed.value.meta.views);
}

test "deserializeOpts ignores unknown fields" {
    const Point = struct { x: i32, y: i32 };

    var parsed = try deserializeOpts(
        Point,
        testing.allocator,
        \\{"x":1,"y":2,"z":99}
    ,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try testing.expectEqual(@as(i32, 1), parsed.value.x);
    try testing.expectEqual(@as(i32, 2), parsed.value.y);
}

test "primitives round-trip" {
    const num = try serialize(testing.allocator, @as(i64, 42));
    defer testing.allocator.free(num);
    try testing.expectEqualStrings("42", num);

    const flag = try serialize(testing.allocator, true);
    defer testing.allocator.free(flag);
    try testing.expectEqualStrings("true", flag);

    const text = try serialize(testing.allocator, "hi");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("\"hi\"", text);

    var parsed_num = try deserialize(i64, testing.allocator, num);
    defer parsed_num.deinit();
    try testing.expectEqual(@as(i64, 42), parsed_num.value);
}
