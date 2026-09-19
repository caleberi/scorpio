const zstd = @import("std");
const fs = @import("../../compat_fs.zig");
const loader = @import("../documents/loader.zig");
const common = @import("common");
const parser = @import("parser.zig");
const deck_mod = @import("deck.zig");

const Tree = loader.Tree;
const Sha256 = zstd.crypto.hash.sha2.Sha256;
const unixTimestamp = common.utils.unixTimestamp;

const max_document_bytes: usize = 64 * 1024 * 1024;
const doc_extensions = [_][]const u8{ ".md", ".markdown" };

pub const audio_extensions = [_][]const u8{ ".mp3", ".wav", ".ogg", ".m4a" };

pub const Config = struct {
    input_dir: []const u8,
    pack_dir: []const u8,
    extra_dirs: []const []const u8 = &.{},
};

pub const Processor = struct {
    allocator: zstd.mem.Allocator,
    config: Config,
    arena: zstd.heap.ArenaAllocator,
    rewrites: zstd.StringHashMap([]const u8),

    pub fn init(allocator: zstd.mem.Allocator, config: Config) Processor {
        return .{
            .allocator = allocator,
            .config = config,
            .arena = zstd.heap.ArenaAllocator.init(allocator),
            .rewrites = zstd.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Processor) void {
        self.rewrites.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn putRewrite(self: *Processor, local: []const u8, url: []const u8) !void {
        const strings = self.arena.allocator();
        try self.rewrites.put(try strings.dupe(u8, local), try strings.dupe(u8, url));
    }

    pub fn run(self: *Processor) !void {
        try fs.cwd().makePath(self.config.pack_dir);
        const strings = self.arena.allocator();

        var entries: zstd.ArrayList(deck_mod.IndexEntry) = .empty;
        defer entries.deinit(self.allocator);

        try self.scanTree(self.config.input_dir, &entries);
        for (self.config.extra_dirs) |dir| {
            try self.scanTree(dir, &entries);
        }

        const index = deck_mod.Index{
            .version = deck_mod.version,
            .generated_at = unixTimestamp(),
            .documents = try strings.dupe(deck_mod.IndexEntry, entries.items),
        };
        const index_bytes = try deck_mod.serializeIndex(self.allocator, index);
        defer self.allocator.free(index_bytes);
        try writeFile(self.config.pack_dir, "presentations.json", index_bytes);
    }

    fn scanTree(self: *Processor, root: []const u8, entries: *zstd.ArrayList(deck_mod.IndexEntry)) !void {
        var tree = Tree.load(self.allocator, root) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer tree.deinit();

        var abs_buf: [zstd.fs.max_path_bytes]u8 = undefined;
        var rel_buf: [zstd.fs.max_path_bytes]u8 = undefined;

        for (tree.files) |id| {
            const rel = try tree.relativePathInto(id, &rel_buf);
            if (rel.len == 0) continue;
            const abs = try tree.pathInto(id, &abs_buf);
            if (!matchesExt(abs, &doc_extensions)) continue;
            if (isHidden(rel)) continue;

            const content = fs.cwd().readFileAlloc(self.allocator, abs, max_document_bytes) catch continue;
            defer self.allocator.free(content);

            if (!parser.containsSlide(content)) {
                if (parser.containsOrphanAnimate(content)) {
                    zstd.log.warn("presentation tags without <slide> in {s}", .{rel});
                }
                continue;
            }

            const slug = stripExtension(rel);
            var compiled = parser.compile(self.arena.allocator(), content, .{
                .slug = try self.arena.allocator().dupe(u8, slug),
                .path = try self.arena.allocator().dupe(u8, rel),
            }) catch |err| {
                zstd.log.warn("failed to compile presentation {s}: {s}", .{ rel, @errorName(err) });
                continue;
            };
            self.rewriteDeck(&compiled);

            const bytes = try deck_mod.serializeDeck(self.allocator, compiled);
            defer self.allocator.free(bytes);

            const out_name = try zstd.fmt.allocPrint(self.arena.allocator(), "{s}.json", .{slug});
            try writeFile(self.config.pack_dir, out_name, bytes);

            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(bytes, &digest, .{});
            const hex = try self.arena.allocator().dupe(u8, &zstd.fmt.bytesToHex(digest, .lower));

            try entries.append(self.allocator, .{
                .slug = try self.arena.allocator().dupe(u8, compiled.slug),
                .title = try self.arena.allocator().dupe(u8, compiled.title),
                .path = try self.arena.allocator().dupe(u8, compiled.path),
                .duration_ms = deck_mod.durationOf(compiled),
                .size = compiled.size,
                .image = try self.arena.allocator().dupe(u8, compiled.image),
                .sha256 = hex,
            });
        }
    }

    fn rewriteDeck(self: *Processor, compiled: *deck_mod.Deck) void {
        if (compiled.soundtrack) |*track| {
            track.url = self.rewriteUrl(track.url);
        }
        if (compiled.image.len > 0) {
            compiled.image = self.rewriteCover(compiled.image);
        }
        for (compiled.slides) |*slide| {
            for (slide.cues) |*cue| {
                cue.url = self.rewriteUrl(cue.url);
            }
            for (slide.nodes) |*node| {
                if (node.src.len > 0) node.src = self.rewriteUrl(node.src);
            }
        }
    }

    /// Keep markdown/HTML cover syntax; rewrite only the local src when mapped.
    fn rewriteCover(self: *Processor, value: []const u8) []const u8 {
        const src = coverSrc(value);
        const mapped = self.rewriteUrl(src);
        if (mapped.ptr == src.ptr and mapped.len == src.len) return value;
        if (zstd.mem.eql(u8, mapped, src)) return value;
        if (zstd.mem.eql(u8, value, src)) return mapped;
        const strings = self.arena.allocator();
        if (zstd.mem.indexOf(u8, value, src)) |at| {
            return zstd.mem.concat(strings, u8, &.{ value[0..at], mapped, value[at + src.len ..] }) catch mapped;
        }
        return mapped;
    }

    fn rewriteUrl(self: *Processor, url: []const u8) []const u8 {
        if (self.rewrites.get(url)) |mapped| return mapped;
        return url;
    }
};

fn writeFile(dir_path: []const u8, name: []const u8, bytes: []const u8) !void {
    const full = try fs.path.join(zstd.heap.page_allocator, &.{ dir_path, name });
    defer zstd.heap.page_allocator.free(full);
    if (fs.path.dirname(full)) |parent| try fs.cwd().makePath(parent);
    try fs.cwd().writeFile(.{ .sub_path = full, .data = bytes });
}

fn matchesExt(path: []const u8, extensions: []const []const u8) bool {
    const ext = fs.path.extension(path);
    for (extensions) |candidate| {
        if (zstd.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn stripExtension(path: []const u8) []const u8 {
    const ext = fs.path.extension(path);
    return path[0 .. path.len - ext.len];
}

fn coverSrc(value: []const u8) []const u8 {
    const trimmed = zstd.mem.trim(u8, value, " \t");
    if (zstd.mem.startsWith(u8, trimmed, "![")) {
        const open = zstd.mem.indexOf(u8, trimmed, "](") orelse return trimmed;
        var start = open + 2;
        while (start < trimmed.len and (trimmed[start] == ' ' or trimmed[start] == '<')) start += 1;
        var end = start;
        while (end < trimmed.len and trimmed[end] != ')' and trimmed[end] != ' ' and trimmed[end] != '>') end += 1;
        if (end > start) return trimmed[start..end];
        return trimmed;
    }
    if (trimmed.len >= 6 and zstd.ascii.eqlIgnoreCase(trimmed[0..6], "<video")) {
        const marker = "src=";
        const at = indexOfIgnoreCase(trimmed, marker) orelse return trimmed;
        var p = at + marker.len;
        while (p < trimmed.len and trimmed[p] == ' ') p += 1;
        if (p >= trimmed.len) return trimmed;
        if (trimmed[p] == '"' or trimmed[p] == '\'') {
            const q = trimmed[p];
            const start = p + 1;
            const close = zstd.mem.indexOfScalarPos(u8, trimmed, start, q) orelse return trimmed;
            return trimmed[start..close];
        }
    }
    return trimmed;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (zstd.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isHidden(rel_path: []const u8) bool {
    var it = zstd.mem.splitScalar(u8, rel_path, fs.path.sep);
    while (it.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return true;
    }
    return false;
}

pub fn splitExtraDirs(allocator: zstd.mem.Allocator, csv: []const u8) ![]const []const u8 {
    const trimmed = zstd.mem.trim(u8, csv, " \t");
    if (trimmed.len == 0) return &.{};
    var list: zstd.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var it = zstd.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        const p = zstd.mem.trim(u8, part, " \t");
        if (p.len == 0) continue;
        try list.append(allocator, p);
    }
    return list.toOwnedSlice(allocator);
}

const testing = zstd.testing;

fn tmpJoin(allocator: zstd.mem.Allocator, tmp: *testing.TmpDir, sub: []const u8) ![]u8 {
    return zstd.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub });
}

test "processor compiles tagged readme and skips sibling without slides" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/blog");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/blog/talk.md",
        .data =
        \\---
        \\title: Demo Talk
        \\image: '![image](./cover.webp)'
        \\---
        \\
        \\# Talk
        \\
        \\<slide id="open" duration="2s">
        \\# Hello
        \\<animate target="title" dur="800ms" ease="linear">
        \\  <keyframe at="0%" translate="0,40" opacity="0"/>
        \\  <keyframe at="100%" translate="0,0" opacity="1"/>
        \\</animate>
        \\</slide>
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/blog/note.md", .data = "# Not a deck\n" });

    const src_path = try tmpJoin(allocator, &tmp, "src");
    defer allocator.free(src_path);
    const pack_dir = try tmpJoin(allocator, &tmp, "pack");
    defer allocator.free(pack_dir);

    var proc = Processor.init(allocator, .{ .input_dir = src_path, .pack_dir = pack_dir });
    defer proc.deinit();
    try proc.putRewrite("./whoosh.mp3", "https://cdn.example.com/whoosh.mp3");
    try proc.putRewrite("./cover.webp", "https://cdn.example.com/cover.webp");
    try proc.run();

    var out_dir = try fs.cwd().openDir(pack_dir, .{});
    defer out_dir.close();

    const index_bytes = try out_dir.readFileAlloc(allocator, "presentations.json", 1024 * 1024);
    defer allocator.free(index_bytes);

    var arena = zstd.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const index = try deck_mod.deserializeIndex(arena.allocator(), index_bytes);
    try testing.expectEqual(@as(usize, 1), index.documents.len);
    try testing.expectEqualStrings("blog/talk", index.documents[0].slug);
    try testing.expectEqualStrings("Demo Talk", index.documents[0].title);
    try testing.expectEqualStrings("![image](https://cdn.example.com/cover.webp)", index.documents[0].image);

    const deck_bytes = try out_dir.readFileAlloc(allocator, "blog/talk.json", 1024 * 1024);
    defer allocator.free(deck_bytes);
    const compiled = try deck_mod.deserializeDeck(arena.allocator(), deck_bytes);
    try testing.expectEqual(@as(usize, 1), compiled.slides.len);
    try testing.expectEqualStrings("open", compiled.slides[0].id);
    try testing.expectEqualStrings("![image](https://cdn.example.com/cover.webp)", compiled.image);
}

test "rewrite map replaces soundtrack url" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var proc = Processor.init(testing.allocator, .{ .input_dir = ".", .pack_dir = "." });
    defer proc.deinit();
    try proc.putRewrite("./audio/talk.mp3", "https://cdn.example.com/talk.mp3");
    try proc.putRewrite("./cover.webp", "https://cdn.example.com/cover.webp");
    try testing.expectEqualStrings("https://cdn.example.com/talk.mp3", proc.rewriteUrl("./audio/talk.mp3"));
    try testing.expectEqualStrings("keep.mp3", proc.rewriteUrl("keep.mp3"));
    try testing.expectEqualStrings(
        "![image](https://cdn.example.com/cover.webp)",
        proc.rewriteCover("![image](./cover.webp)"),
    );
}
