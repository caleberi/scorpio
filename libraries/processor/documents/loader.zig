const zstd = @import("std");
const fs = @import("../../compat_fs.zig");
const Allocator = zstd.mem.Allocator;

pub const no_parent: u32 = zstd.math.maxInt(u32);

pub const Kind = enum(u8) {
    file = 0,
    folder = 1,
};

pub const Node = extern struct {
    size: u64,
    mtime: i64,
    name_off: u32,
    parent: u32,
    first_child: u32,
    child_count: u16,
    name_len: u8,
    kind: Kind,
};

comptime {
    zstd.debug.assert(@sizeOf(Node) == 32);
    zstd.debug.assert(@alignOf(Node) == 8);
}

pub const Tree = struct {
    arena: zstd.heap.ArenaAllocator,
    root_path: []const u8,
    names: []const u8,
    nodes: []Node,
    files: []u32,

    pub fn load(gpa: Allocator, path: []const u8) !Tree {
        var arena = zstd.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const root_path = try fs.realpathAlloc(gpa, path);
        defer gpa.free(root_path);

        var root_dir = try fs.openDirAbsolute(root_path, .{ .iterate = true });
        defer root_dir.close();
        const root_stat = try root_dir.stat();

        const root_name = fs.path.basename(root_path);
        if (root_name.len > zstd.math.maxInt(u8)) return error.NameTooLong;

        var nodes: zstd.ArrayList(Node) = .empty;
        defer nodes.deinit(gpa);
        var names: zstd.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        var files: zstd.ArrayList(u32) = .empty;
        defer files.deinit(gpa);

        try names.appendSlice(gpa, root_name);
        try nodes.append(gpa, .{
            .size = root_stat.size,
            .mtime = @intCast(root_stat.mtime),
            .name_off = 0,
            .parent = no_parent,
            .first_child = 0,
            .child_count = 0,
            .name_len = @intCast(root_name.len),
            .kind = .folder,
        });

        try loadChildren(gpa, &nodes, &names, &files, 0, root_dir);

        const a = arena.allocator();
        const root_path_owned = try a.dupe(u8, root_path);
        const names_owned = try a.dupe(u8, names.items);
        const nodes_owned = try a.dupe(Node, nodes.items);
        const files_owned = try a.dupe(u32, files.items);

        return .{
            .arena = arena,
            .root_path = root_path_owned,
            .names = names_owned,
            .nodes = nodes_owned,
            .files = files_owned,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn name(self: *const Tree, id: u32) []const u8 {
        const node = self.nodes[id];
        return self.names[node.name_off..][0..node.name_len];
    }

    pub fn children(self: *const Tree, id: u32) []const Node {
        const node = self.nodes[id];
        if (node.child_count == 0) return &.{};
        return self.nodes[node.first_child..][0..node.child_count];
    }

    pub fn pathInto(self: *const Tree, id: u32, buf: []u8) error{PathTooLong}![]const u8 {
        var cur = id;
        var end: usize = buf.len;
        var first = true;
        while (true) {
            const node = self.nodes[cur];
            if (node.parent == no_parent) {
                if (!first) {
                    if (end == 0) return error.PathTooLong;
                    end -= 1;
                    buf[end] = '/';
                }
                if (self.root_path.len > end) return error.PathTooLong;
                end -= self.root_path.len;
                @memcpy(buf[end..][0..self.root_path.len], self.root_path);
                break;
            }
            const part = self.name(cur);
            if (!first) {
                if (end == 0) return error.PathTooLong;
                end -= 1;
                buf[end] = '/';
            }
            first = false;
            if (part.len > end) return error.PathTooLong;
            end -= part.len;
            @memcpy(buf[end..][0..part.len], part);
            cur = node.parent;
        }
        return buf[end..];
    }

    pub fn relativePathInto(self: *const Tree, id: u32, buf: []u8) error{PathTooLong}![]const u8 {
        if (self.nodes[id].parent == no_parent) return buf[0..0];

        var cur = id;
        var end: usize = buf.len;
        var first = true;
        while (true) {
            const node = self.nodes[cur];
            if (node.parent == no_parent) break;
            const part = self.name(cur);
            if (!first) {
                if (end == 0) return error.PathTooLong;
                end -= 1;
                buf[end] = '/';
            }
            first = false;
            if (part.len > end) return error.PathTooLong;
            end -= part.len;
            @memcpy(buf[end..][0..part.len], part);
            cur = node.parent;
        }
        return buf[end..];
    }

    pub fn get(self: *const Tree, path: []const u8) ?u32 {
        const rel = relativeOf(self.root_path, path) orelse return null;
        if (rel.len == 0) return 0;

        var id: u32 = 0;
        var it = zstd.mem.splitScalar(u8, rel, '/');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            const node = self.nodes[id];
            const kids = self.children(id);
            const ctx = NameSearch{ .names = self.names, .key = part };
            const off = zstd.sort.binarySearch(Node, kids, ctx, NameSearch.order) orelse return null;
            id = node.first_child + @as(u32, @intCast(off));
        }
        return id;
    }
};

const NameSearch = struct {
    names: []const u8,
    key: []const u8,

    fn order(ctx: NameSearch, node: Node) zstd.math.Order {
        const name = ctx.names[node.name_off..][0..node.name_len];
        return zstd.mem.order(u8, ctx.key, name);
    }
};

fn relativeOf(root_path: []const u8, path: []const u8) ?[]const u8 {
    if (zstd.mem.eql(u8, path, root_path)) return "";
    if (path.len > root_path.len + 1 and
        path[root_path.len] == '/' and
        zstd.mem.startsWith(u8, path, root_path))
    {
        return path[root_path.len + 1 ..];
    }
    return path;
}

fn loadChildren(
    gpa: Allocator,
    nodes: *zstd.ArrayList(Node),
    names: *zstd.ArrayList(u8),
    files: *zstd.ArrayList(u32),
    parent: u32,
    dir: fs.Dir,
) !void {
    const start: u32 = @intCast(nodes.items.len);

    var iter = try dir.iterate();
    defer iter.deinit();

    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = try dir.statFile(entry.name);
                try appendNode(gpa, nodes, names, parent, entry.name, .file, stat);
            },
            .directory => {
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                const stat = try child.stat();
                try appendNode(gpa, nodes, names, parent, entry.name, .folder, stat);
            },
            else => {},
        }
    }

    const count = nodes.items.len - start;
    if (count > zstd.math.maxInt(u16)) return error.TooManyChildren;

    const siblings = nodes.items[start .. start + count];
    zstd.mem.sort(Node, siblings, names.items, nodeNameLessThan);

    nodes.items[parent].first_child = if (count == 0) 0 else start;
    nodes.items[parent].child_count = @intCast(count);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const id = start + i;
        const node = nodes.items[id];
        if (node.kind == .file) {
            try files.append(gpa, id);
            continue;
        }

        const child_name = names.items[node.name_off..][0..node.name_len];
        var child_dir = try dir.openDir(child_name, .{ .iterate = true });
        defer child_dir.close();
        try loadChildren(gpa, nodes, names, files, id, child_dir);
    }
}

fn appendNode(
    gpa: Allocator,
    nodes: *zstd.ArrayList(Node),
    names: *zstd.ArrayList(u8),
    parent: u32,
    basename: []const u8,
    kind: Kind,
    stat: fs.Stat,
) !void {
    if (basename.len > zstd.math.maxInt(u8)) return error.NameTooLong;
    if (names.items.len > zstd.math.maxInt(u32) - basename.len) return error.Overflow;
    if (nodes.items.len >= zstd.math.maxInt(u32)) return error.Overflow;

    const name_off: u32 = @intCast(names.items.len);
    try names.appendSlice(gpa, basename);
    try nodes.append(gpa, .{
        .size = stat.size,
        .mtime = @intCast(stat.mtime),
        .name_off = name_off,
        .parent = parent,
        .first_child = 0,
        .child_count = 0,
        .name_len = @intCast(basename.len),
        .kind = kind,
    });
}

fn nodeNameLessThan(name_pool: []const u8, a: Node, b: Node) bool {
    const an = name_pool[a.name_off..][0..a.name_len];
    const bn = name_pool[b.name_off..][0..b.name_len];
    return zstd.mem.lessThan(u8, an, bn);
}

test "Tree.load recursively indexes folders and files" {
    const allocator = zstd.testing.allocator;

    var tmp = zstd.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = zstd.testing.io;

    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "root.txt", .data = "root" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/nested.txt", .data = "nested" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/deep.txt", .data = "deep" });

    var root_buf: [zstd.Io.Dir.max_path_bytes]u8 = undefined;
    const root_n = try tmp.dir.realPath(io, &root_buf);
    const root_path = try allocator.dupe(u8, root_buf[0..root_n]);
    defer allocator.free(root_path);

    var tree = try Tree.load(allocator, root_path);
    defer tree.deinit();

    try zstd.testing.expectEqual(@as(usize, 3), tree.files.len);
    try zstd.testing.expect(tree.nodes.len >= 4);
    try zstd.testing.expectEqual(no_parent, tree.nodes[0].parent);
    try zstd.testing.expectEqual(Kind.folder, tree.nodes[0].kind);

    const nested_path = try fs.path.join(allocator, &.{
        tree.root_path,
        "a",
        "nested.txt",
    });
    defer allocator.free(nested_path);

    const nested_id = tree.get(nested_path).?;
    try zstd.testing.expectEqualStrings("nested.txt", tree.name(nested_id));
    try zstd.testing.expect(tree.nodes[nested_id].size > 0);
    try zstd.testing.expectEqual(tree.get("a/nested.txt"), nested_id);

    const parent_id = tree.nodes[nested_id].parent;
    try zstd.testing.expectEqualStrings("a", tree.name(parent_id));

    const parent_kids = tree.children(parent_id);
    try zstd.testing.expectEqual(@as(usize, 2), parent_kids.len);
    try zstd.testing.expectEqualStrings("b", tree.name(tree.nodes[parent_id].first_child));
    try zstd.testing.expectEqualStrings("nested.txt", tree.name(tree.nodes[parent_id].first_child + 1));
    try zstd.testing.expect(zstd.mem.lessThan(
        u8,
        tree.names[parent_kids[0].name_off..][0..parent_kids[0].name_len],
        tree.names[parent_kids[1].name_off..][0..parent_kids[1].name_len],
    ));

    var found_nested = false;
    for (parent_kids, 0..) |child, i| {
        _ = child;
        const child_id = tree.nodes[parent_id].first_child + @as(u32, @intCast(i));
        if (zstd.mem.eql(u8, tree.name(child_id), "nested.txt")) {
            found_nested = true;
            break;
        }
    }
    try zstd.testing.expect(found_nested);

    var path_buf: [zstd.Io.Dir.max_path_bytes]u8 = undefined;
    const abs = try tree.pathInto(nested_id, &path_buf);
    try zstd.testing.expectEqualStrings(nested_path, abs);

    var rel_buf: [zstd.Io.Dir.max_path_bytes]u8 = undefined;
    const rel = try tree.relativePathInto(nested_id, &rel_buf);
    try zstd.testing.expectEqualStrings("a/nested.txt", rel);

    const content = try fs.cwd().readFileAlloc(allocator, abs, 1024);
    defer allocator.free(content);
    try zstd.testing.expectEqualStrings("nested", content);
}
