const zstd = @import("std");
const Allocator = zstd.mem.Allocator;

/// Convert Unix timestamp to seconds since epoch
/// See: https://man7.org/linux/man-pages/man2/time.2.html
pub fn unixTimestamp() i64 {
    return @extern(
        *const fn (?*c_long) callconv(.c) c_long,
        .{ .name = "time" },
    )(null);
}

fn resolveIndex(index: isize, len: usize) usize {
    if (index < 0) {
        const from_end = @as(isize, @intCast(len)) + index;
        if (from_end < 0) return 0;
        return @intCast(from_end);
    }
    return @min(@as(usize, @intCast(index)), len);
}

fn resolveAtIndex(index: isize, len: usize) ?usize {
    if (len == 0) return null;
    if (index < 0) {
        const from_end = @as(isize, @intCast(len)) + index;
        if (from_end < 0) return null;
        return @intCast(from_end);
    }
    const i: usize = @intCast(index);
    if (i >= len) return null;
    return i;
}

pub fn map(
    comptime T: type,
    comptime R: type,
    allocator: Allocator,
    items: []const T,
    context: anytype,
    comptime f: fn (@TypeOf(context), T) R,
) ![]R {
    const result = try allocator.alloc(R, items.len);
    errdefer allocator.free(result);
    for (items, 0..) |item, i| {
        result[i] = f(context, item);
    }
    return result;
}

pub fn filter(
    comptime T: type,
    allocator: Allocator,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) ![]T {
    var list: zstd.ArrayList(T) = .empty;
    errdefer list.deinit(allocator);
    for (items) |item| {
        if (pred(context, item)) {
            try list.append(allocator, item);
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn flatMap(
    comptime T: type,
    comptime R: type,
    allocator: Allocator,
    items: []const T,
    context: anytype,
    comptime f: fn (@TypeOf(context), T) []const R,
) ![]R {
    var list: zstd.ArrayList(R) = .empty;
    errdefer list.deinit(allocator);
    for (items) |item| {
        try list.appendSlice(allocator, f(context, item));
    }
    return try list.toOwnedSlice(allocator);
}

pub fn reduce(
    comptime T: type,
    comptime R: type,
    items: []const T,
    initial: R,
    context: anytype,
    comptime f: fn (@TypeOf(context), R, T) R,
) R {
    var acc = initial;
    for (items) |item| {
        acc = f(context, acc, item);
    }
    return acc;
}

pub fn reduceRight(
    comptime T: type,
    comptime R: type,
    items: []const T,
    initial: R,
    context: anytype,
    comptime f: fn (@TypeOf(context), R, T) R,
) R {
    var acc = initial;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        acc = f(context, acc, items[i]);
    }
    return acc;
}

pub fn find(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) ?T {
    for (items) |item| {
        if (pred(context, item)) return item;
    }
    return null;
}

pub fn findIndex(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) ?usize {
    for (items, 0..) |item, i| {
        if (pred(context, item)) return i;
    }
    return null;
}

pub fn findLast(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) ?T {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (pred(context, items[i])) return items[i];
    }
    return null;
}

pub fn findLastIndex(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) ?usize {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (pred(context, items[i])) return i;
    }
    return null;
}

pub fn some(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) bool {
    for (items) |item| {
        if (pred(context, item)) return true;
    }
    return false;
}

pub fn every(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime pred: fn (@TypeOf(context), T) bool,
) bool {
    for (items) |item| {
        if (!pred(context, item)) return false;
    }
    return true;
}

pub fn forEach(
    comptime T: type,
    items: []const T,
    context: anytype,
    comptime f: fn (@TypeOf(context), T) void,
) void {
    for (items) |item| {
        f(context, item);
    }
}

pub fn includes(comptime T: type, items: []const T, value: T) bool {
    return indexOf(T, items, value) != null;
}

pub fn indexOf(comptime T: type, items: []const T, value: T) ?usize {
    for (items, 0..) |item, i| {
        if (zstd.meta.eql(item, value)) return i;
    }
    return null;
}

pub fn lastIndexOf(comptime T: type, items: []const T, value: T) ?usize {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (zstd.meta.eql(items[i], value)) return i;
    }
    return null;
}

pub fn at(comptime T: type, items: []const T, index: isize) ?T {
    const i = resolveAtIndex(index, items.len) orelse return null;
    return items[i];
}

pub fn slice(
    comptime T: type,
    allocator: Allocator,
    items: []const T,
    start: isize,
    end: ?isize,
) ![]T {
    const from = resolveIndex(start, items.len);
    const to = if (end) |e| resolveIndex(e, items.len) else items.len;
    if (from >= to) return try allocator.alloc(T, 0);
    return try allocator.dupe(T, items[from..to]);
}

pub fn concat(comptime T: type, allocator: Allocator, a: []const T, b: []const T) ![]T {
    const result = try allocator.alloc(T, a.len + b.len);
    @memcpy(result[0..a.len], a);
    @memcpy(result[a.len..], b);
    return result;
}

pub fn flat(
    comptime T: type,
    allocator: Allocator,
    items: []const []const T,
    depth: usize,
) ![]T {
    if (depth == 0) return try allocator.alloc(T, 0);

    var total: usize = 0;
    for (items) |inner| total += inner.len;

    const result = try allocator.alloc(T, total);
    errdefer allocator.free(result);

    var offset: usize = 0;
    for (items) |inner| {
        @memcpy(result[offset .. offset + inner.len], inner);
        offset += inner.len;
    }
    return result;
}

pub fn join(
    allocator: Allocator,
    items: []const []const u8,
    separator: []const u8,
) ![]u8 {
    if (items.len == 0) return try allocator.alloc(u8, 0);

    var total: usize = separator.len * (items.len - 1);
    for (items) |item| total += item.len;

    const result = try allocator.alloc(u8, total);
    errdefer allocator.free(result);

    var offset: usize = 0;
    for (items, 0..) |item, i| {
        if (i > 0) {
            @memcpy(result[offset .. offset + separator.len], separator);
            offset += separator.len;
        }
        @memcpy(result[offset .. offset + item.len], item);
        offset += item.len;
    }
    return result;
}

pub const WithError = error{IndexOutOfBounds};

pub fn with(
    comptime T: type,
    allocator: Allocator,
    items: []const T,
    index: isize,
    value: T,
) (Allocator.Error || WithError)![]T {
    const i = resolveAtIndex(index, items.len) orelse return error.IndexOutOfBounds;
    const owned = try allocator.dupe(T, items);
    owned[i] = value;
    return owned;
}

pub fn toReversed(comptime T: type, allocator: Allocator, items: []const T) ![]T {
    const result = try allocator.dupe(T, items);
    reverse(T, result);
    return result;
}

pub fn toSorted(
    comptime T: type,
    allocator: Allocator,
    items: []const T,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) ![]T {
    const result = try allocator.dupe(T, items);
    sort(T, result, context, lessThan);
    return result;
}

pub fn reverse(comptime T: type, items: []T) void {
    if (items.len < 2) return;
    var i: usize = 0;
    var j = items.len - 1;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        const tmp = items[i];
        items[i] = items[j];
        items[j] = tmp;
    }
}

pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    zstd.mem.sort(T, items, context, lessThan);
}

pub fn fill(comptime T: type, items: []T, value: T, start: isize, end: ?isize) void {
    const from = resolveIndex(start, items.len);
    const to = if (end) |e| resolveIndex(e, items.len) else items.len;
    if (from >= to) return;
    @memset(items[from..to], value);
}

pub fn copyWithin(comptime T: type, items: []T, target: isize, start: isize, end: ?isize) void {
    const len = items.len;
    const to = resolveIndex(target, len);
    const from = resolveIndex(start, len);
    const until = if (end) |e| resolveIndex(e, len) else len;
    if (from >= until or to >= len) return;

    const count = @min(until - from, len - to);
    if (count == 0) return;

    const tmp_src = items[from .. from + count];
    const tmp_dst = items[to .. to + count];
    if (to <= from) {
        zstd.mem.copyForwards(T, tmp_dst, tmp_src);
    } else {
        zstd.mem.copyBackwards(T, tmp_dst, tmp_src);
    }
}

// --- tests ---

fn double(_: void, n: i32) usize {
    return @intCast(n * 2);
}

fn toUsize(_: void, n: i32) usize {
    return @intCast(n);
}

fn isEven(_: void, n: i32) bool {
    return @mod(n, 2) == 0;
}

fn isOdd(_: void, n: i32) bool {
    return @mod(n, 2) != 0;
}

fn add(_: void, acc: i32, n: i32) i32 {
    return acc + n;
}

fn subtract(_: void, acc: i32, n: i32) i32 {
    return acc - n;
}

fn lessI32(_: void, a: i32, b: i32) bool {
    return a < b;
}

fn expand(_: void, n: i32) []const i32 {
    return switch (n) {
        1 => &[_]i32{ 1, 10 },
        2 => &[_]i32{ 2, 20 },
        else => &[_]i32{},
    };
}

const testing = zstd.testing;

fn MapTest(comptime T: type, comptime R: type) type {
    return struct {
        input: []const T,
        expected: []const R,
        func: fn (void, T) R,
    };
}

test MapTest {
    const TestCase = MapTest(i32, usize);
    const tests = [_]TestCase{
        TestCase{ .input = &[_]i32{ 1, 2, 3 }, .expected = &[_]usize{ 1, 2, 3 }, .func = toUsize },
        TestCase{ .input = &[_]i32{ 4, 5, 6 }, .expected = &[_]usize{ 8, 10, 12 }, .func = double },
        TestCase{ .input = &[_]i32{ 13, 14, 15 }, .expected = &[_]usize{ 26, 28, 30 }, .func = double },
    };

    inline for (tests) |t| {
        const result = try map(zstd.meta.Child(@TypeOf(t.input)), zstd.meta.Child(@TypeOf(t.expected)), testing.allocator, t.input, {}, t.func);
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(zstd.meta.Child(@TypeOf(t.expected)), t.expected, result);
    }
}

fn FilterTest(comptime T: type, comptime R: type) type {
    return struct {
        input: []const T,
        expected: []const R,
        func: fn (void, T) bool,
    };
}

test FilterTest {
    const TestCase = FilterTest(i32, i32);
    const tests = [_]TestCase{
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = &[_]i32{ 2, 4 }, .func = isEven },
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = &[_]i32{ 2, 4 }, .func = isEven },
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = &[_]i32{ 1, 3, 5 }, .func = isOdd },
    };

    inline for (tests) |t| {
        const result = try filter(zstd.meta.Child(@TypeOf(t.input)), testing.allocator, t.input, {}, t.func);
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(zstd.meta.Child(@TypeOf(t.expected)), t.expected, result);
    }
}

fn ReduceTest(comptime T: type, comptime R: type) type {
    return struct {
        input: []const T,
        initial: R,
        expected: R,
        func: fn (void, R, T) R,
    };
}

test ReduceTest {
    const TestCase = ReduceTest(i32, i32);
    const leftTest = [_]TestCase{
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .initial = 15, .expected = 30, .func = add },
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .initial = 30, .expected = 15, .func = subtract },
        TestCase{ .input = &[_]i32{ 1, 2, 3, 4 }, .initial = 15, .expected = 25, .func = add },
    };

    inline for (leftTest) |t| {
        const result = reduce(zstd.meta.Child(@TypeOf(t.input)), @TypeOf(t.expected), t.input, t.initial, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const TestCaseRight = ReduceTest(i32, i32);
    const rightTests = [_]TestCaseRight{
        TestCaseRight{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .initial = 15, .expected = 30, .func = add },
        TestCaseRight{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .initial = 30, .expected = 15, .func = subtract },
        TestCaseRight{ .input = &[_]i32{ 1, 2, 3, 4 }, .initial = 15, .expected = 25, .func = add },
    };

    inline for (rightTests) |t| {
        const result = reduceRight(zstd.meta.Child(@TypeOf(t.input)), @TypeOf(t.expected), t.input, t.initial, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }
}

fn FindTest(comptime T: type, comptime R: type) type {
    return struct {
        input: []const T,
        expected: R,
        func: fn (void, T) bool,
    };
}

fn IndexOfTest(comptime T: type, comptime R: type) type {
    return struct {
        input: []const T,
        value: T,
        expected: R,
    };
}

test FindTest {
    const FindCase = FindTest(i32, ?i32);
    const findTests = [_]FindCase{
        .{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = 2, .func = isEven },
        .{ .input = &[_]i32{ 1, 3, 5 }, .expected = null, .func = isEven },
    };
    inline for (findTests) |t| {
        const result = find(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const IndexCase = FindTest(i32, ?usize);
    const findIndexTests = [_]IndexCase{
        .{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = 1, .func = isEven },
        .{ .input = &[_]i32{ 1, 3, 5 }, .expected = null, .func = isEven },
    };
    inline for (findIndexTests) |t| {
        const result = findIndex(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const findLastTests = [_]FindCase{
        .{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = 4, .func = isEven },
        .{ .input = &[_]i32{ 1, 3, 5 }, .expected = null, .func = isEven },
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .expected = 2, .func = isEven },
    };
    inline for (findLastTests) |t| {
        const result = findLast(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const findLastIndexTests = [_]IndexCase{
        .{ .input = &[_]i32{ 1, 2, 3, 4, 5 }, .expected = 3, .func = isEven },
        .{ .input = &[_]i32{ 1, 3, 5 }, .expected = null, .func = isEven },
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .expected = 3, .func = isEven },
    };
    inline for (findLastIndexTests) |t| {
        const result = findLastIndex(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const BoolCase = FindTest(i32, bool);
    const someTests = [_]BoolCase{
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .expected = true, .func = isEven },
        .{ .input = &[_]i32{ 1, 3, 5 }, .expected = false, .func = isEven },
    };
    inline for (someTests) |t| {
        const result = some(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const everyTests = [_]BoolCase{
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .expected = false, .func = isEven },
        .{ .input = &[_]i32{ 2, 4, 6 }, .expected = true, .func = isEven },
    };
    inline for (everyTests) |t| {
        const result = every(zstd.meta.Child(@TypeOf(t.input)), t.input, {}, t.func);
        try testing.expectEqual(t.expected, result);
    }

    const IncludesCase = IndexOfTest(i32, bool);
    const includesTests = [_]IncludesCase{
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .value = 5, .expected = true },
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .value = 9, .expected = false },
    };
    inline for (includesTests) |t| {
        const result = includes(zstd.meta.Child(@TypeOf(t.input)), t.input, t.value);
        try testing.expectEqual(t.expected, result);
    }

    const ValueIndexCase = IndexOfTest(i32, ?usize);
    const indexOfTests = [_]ValueIndexCase{
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .value = 2, .expected = 1 },
    };
    inline for (indexOfTests) |t| {
        const result = indexOf(zstd.meta.Child(@TypeOf(t.input)), t.input, t.value);
        try testing.expectEqual(t.expected, result);
    }

    const lastIndexOfTests = [_]ValueIndexCase{
        .{ .input = &[_]i32{ 1, 2, 3, 2, 5 }, .value = 2, .expected = 3 },
    };
    inline for (lastIndexOfTests) |t| {
        const result = lastIndexOf(zstd.meta.Child(@TypeOf(t.input)), t.input, t.value);
        try testing.expectEqual(t.expected, result);
    }
}

pub fn SliceTest(comptime T: type) type {
    return struct {
        input: []const T,
        start: isize,
        end: ?isize,
        expected: []const T,
    };
}

test SliceTest {
    const SliceCase = SliceTest(i32);
    const tests = [_]SliceCase{
        .{ .input = &[_]i32{ 0, 1, 2, 3, 4 }, .start = 1, .end = 4, .expected = &[_]i32{ 1, 2, 3 } },
        .{ .input = &[_]i32{ 0, 1, 2, 3, 4 }, .start = -2, .end = null, .expected = &[_]i32{ 3, 4 } },
        .{ .input = &[_]i32{ 0, 1, 2, 3, 4 }, .start = -3, .end = -1, .expected = &[_]i32{ 2, 3 } },
    };

    inline for (tests) |t| {
        const result = try slice(zstd.meta.Child(@TypeOf(t.input)), testing.allocator, t.input, t.start, t.end);
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(zstd.meta.Child(@TypeOf(t.expected)), t.expected, result);
    }
}

test "concat flat flatMap join" {
    const a = [_]i32{ 1, 2 };
    const b = [_]i32{ 3, 4 };
    const joined = try concat(i32, testing.allocator, &a, &b);
    defer testing.allocator.free(joined);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4 }, joined);

    const nested = [_][]const i32{ &[_]i32{ 1, 2 }, &[_]i32{3}, &[_]i32{ 4, 5 } };
    const flattened = try flat(i32, testing.allocator, &nested, 1);
    defer testing.allocator.free(flattened);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3, 4, 5 }, flattened);

    const src = [_]i32{ 1, 2 };
    const fm = try flatMap(i32, i32, testing.allocator, &src, {}, expand);
    defer testing.allocator.free(fm);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 10, 2, 20 }, fm);

    const parts = [_][]const u8{ "a", "b", "c" };
    const text = try join(testing.allocator, &parts, ",");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a,b,c", text);
}

test "toReversed reverse sort with at" {
    const items = [_]i32{ 3, 1, 2 };
    const rev = try toReversed(i32, testing.allocator, &items);
    defer testing.allocator.free(rev);
    try testing.expectEqualSlices(i32, &[_]i32{ 2, 1, 3 }, rev);

    var mutable = [_]i32{ 3, 1, 2 };
    reverse(i32, mutable[0..]);
    try testing.expectEqualSlices(i32, &[_]i32{ 2, 1, 3 }, &mutable);

    var to_sort = [_]i32{ 3, 1, 2 };
    sort(i32, to_sort[0..], {}, lessI32);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, &to_sort);

    const sorted = try toSorted(i32, testing.allocator, &items, {}, lessI32);
    defer testing.allocator.free(sorted);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, sorted);

    const replaced = try with(i32, testing.allocator, &items, 1, 9);
    defer testing.allocator.free(replaced);
    try testing.expectEqualSlices(i32, &[_]i32{ 3, 9, 2 }, replaced);

    try testing.expectEqual(@as(?i32, 2), at(i32, &items, -1));
    try testing.expectEqual(@as(?i32, null), at(i32, &items, 9));
}

test "fill and copyWithin" {
    var items = [_]i32{ 1, 2, 3, 4, 5 };
    fill(i32, items[0..], 0, 1, 4);
    try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 5 }, &items);

    var copy_items = [_]i32{ 1, 2, 3, 4, 5 };
    copyWithin(i32, copy_items[0..], 0, 3, null);
    try testing.expectEqualSlices(i32, &[_]i32{ 4, 5, 3, 4, 5 }, &copy_items);
}

test "forEach side effects" {
    var sum: i32 = 0;
    const Ctx = struct {
        sum: *i32,
        fn call(ctx: @This(), n: i32) void {
            ctx.sum.* += n;
        }
    };
    const items = [_]i32{ 1, 2, 3 };
    forEach(i32, &items, Ctx{ .sum = &sum }, Ctx.call);
    try testing.expectEqual(@as(i32, 6), sum);
}
