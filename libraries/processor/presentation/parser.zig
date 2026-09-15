const zstd = @import("std");
const deck_mod = @import("deck.zig");
const animation = @import("renderer/animation.zig");
const carousel = @import("renderer/carousel.zig");

pub const has_slide_tag = "<slide";

pub fn containsSlide(content: []const u8) bool {
    return findSlideOpen(content, 0) != null;
}

pub fn containsOrphanAnimate(content: []const u8) bool {
    if (containsSlide(content)) return false;
    return indexOfIgnoreCase(content, "<animate") != null;
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

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return zstd.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// `<slide>` mentions in prose are ignored. A real open tag has whitespace before attributes.
fn findSlideOpen(haystack: []const u8, start: usize) ?usize {
    var i = start;
    while (i < haystack.len) {
        const rel = indexOfIgnoreCase(haystack[i..], has_slide_tag) orelse return null;
        const at = i + rel;
        const after = at + has_slide_tag.len;
        if (after < haystack.len) {
            switch (haystack[after]) {
                ' ', '\t', '\n', '\r' => return at,
                else => {},
            }
        }
        i = at + 1;
    }
    return null;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return zstd.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

const Frontmatter = struct {
    title: []const u8 = "",
    soundtrack: []const u8 = "",
    image: []const u8 = "",
    fps: u32 = 30,
    width: u32 = 1920,
    height: u32 = 1080,
    background: []const u8 = "#0a0d14",
    color: []const u8 = "#eef1f7",
    font: []const u8 = "Bricolage Grotesque, Inter, system-ui, sans-serif",
    body: []const u8,
};

fn stripFrontmatter(content: []const u8) Frontmatter {
    var meta = Frontmatter{ .body = content };
    if (!zstd.mem.startsWith(u8, content, "---")) return meta;
    const end = zstd.mem.indexOfPos(u8, content, 3, "\n---") orelse return meta;
    const yaml = content[3..end];
    meta.body = zstd.mem.trim(u8, content[end + 4 ..], "\n\r");

    var it = zstd.mem.splitScalar(u8, yaml, '\n');
    while (it.next()) |line_raw| {
        const line = zstd.mem.trim(u8, line_raw, " \t\r");
        const colon = zstd.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = zstd.mem.trim(u8, line[0..colon], " \t");
        var value = zstd.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
            if (value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
        }
        if (zstd.mem.eql(u8, key, "title")) meta.title = value;
        if (zstd.mem.eql(u8, key, "soundtrack")) meta.soundtrack = value;
        if (zstd.mem.eql(u8, key, "image")) meta.image = value;
        if (zstd.mem.eql(u8, key, "background") or zstd.mem.eql(u8, key, "bg")) meta.background = value;
        if (zstd.mem.eql(u8, key, "color") or zstd.mem.eql(u8, key, "fill")) meta.color = value;
        if (zstd.mem.eql(u8, key, "font") or zstd.mem.eql(u8, key, "font-family")) meta.font = value;
        if (zstd.mem.eql(u8, key, "fps")) {
            meta.fps = zstd.fmt.parseInt(u32, value, 10) catch meta.fps;
        }
        if (zstd.mem.eql(u8, key, "size")) {
            var dim = zstd.mem.splitAny(u8, value, "xX,");
            if (dim.next()) |w| meta.width = zstd.fmt.parseInt(u32, zstd.mem.trim(u8, w, " "), 10) catch meta.width;
            if (dim.next()) |h| meta.height = zstd.fmt.parseInt(u32, zstd.mem.trim(u8, h, " "), 10) catch meta.height;
        }
    }
    return meta;
}

pub fn parseDurationMs(text: []const u8) i64 {
    const t = zstd.mem.trim(u8, text, " \t");
    if (t.len == 0) return 0;
    if (endsWithIgnoreCase(t, "ms")) {
        const n = t[0 .. t.len - 2];
        return zstd.fmt.parseInt(i64, zstd.mem.trim(u8, n, " "), 10) catch 0;
    }
    if (endsWithIgnoreCase(t, "s")) {
        const n = t[0 .. t.len - 1];
        if (zstd.mem.indexOfScalar(u8, n, '.') != null) {
            const secs = zstd.fmt.parseFloat(f32, zstd.mem.trim(u8, n, " ")) catch return 0;
            return @intFromFloat(secs * 1000);
        }
        const secs = zstd.fmt.parseInt(i64, zstd.mem.trim(u8, n, " "), 10) catch 0;
        return secs * 1000;
    }
    return zstd.fmt.parseInt(i64, t, 10) catch 0;
}

fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len < tag.len) : (i += 1) {
        if (!zstd.ascii.eqlIgnoreCase(tag[i .. i + name.len], name)) continue;
        var p = i + name.len;
        while (p < tag.len and tag[p] == ' ') p += 1;
        if (p >= tag.len or tag[p] != '=') continue;
        p += 1;
        while (p < tag.len and tag[p] == ' ') p += 1;
        if (p >= tag.len) return null;
        if (tag[p] == '"' or tag[p] == '\'') {
            const q = tag[p];
            const start = p + 1;
            const close = zstd.mem.indexOfScalarPos(u8, tag, start, q) orelse return tag[start..];
            return tag[start..close];
        }
        const start = p;
        while (p < tag.len and tag[p] != ' ' and tag[p] != '>' and tag[p] != '/') p += 1;
        return tag[start..p];
    }
    return null;
}

const RawSlide = struct {
    id: []const u8,
    duration_ms: i64,
    transition: []const u8,
    inner: []const u8,
    background: []const u8 = "",
    color: []const u8 = "",
    font: []const u8 = "",
};

fn collectSlides(allocator: zstd.mem.Allocator, body: []const u8) ![]RawSlide {
    var slides: zstd.ArrayList(RawSlide) = .empty;
    errdefer slides.deinit(allocator);
    var i: usize = 0;
    var auto_n: usize = 0;
    while (i < body.len) {
        const rel = findSlideOpen(body, i) orelse break;
        const start = rel;
        const tag_end = zstd.mem.indexOfScalarPos(u8, body, start, '>') orelse break;
        const tag = body[start .. tag_end + 1];
        const inner_start = tag_end + 1;
        const close_rel = indexOfIgnoreCase(body[inner_start..], "</slide>") orelse break;
        const inner = body[inner_start .. inner_start + close_rel];
        auto_n += 1;
        const id = attrValue(tag, "id") orelse try zstd.fmt.allocPrint(allocator, "slide-{d}", .{auto_n});
        const dur_raw = attrValue(tag, "duration") orelse "4s";
        const trans = attrValue(tag, "transition") orelse "none";
        try slides.append(allocator, .{
            .id = id,
            .duration_ms = parseDurationMs(dur_raw),
            .transition = trans,
            .inner = inner,
            .background = attrValue(tag, "background") orelse attrValue(tag, "bg") orelse "",
            .color = attrValue(tag, "color") orelse attrValue(tag, "fill") orelse "",
            .font = attrValue(tag, "font") orelse attrValue(tag, "font-family") orelse "",
        });
        i = inner_start + close_rel + "</slide>".len;
    }
    return slides.toOwnedSlice(allocator);
}

const Pair = struct { x: f32, y: f32 };
const RangePair = struct { from: Pair, to: Pair };
const RangeF = struct { from: f32, to: f32 };

const Kf = struct {
    t_ms: i64,
    translate: ?Pair,
    scale: ?Pair,
    rotate: ?f32,
    opacity: ?f32,
    ease: []const u8,
};

fn parsePair(text: []const u8) Pair {
    var it = zstd.mem.splitAny(u8, zstd.mem.trim(u8, text, " \t"), ", ");
    const first = it.next() orelse return .{ .x = 0, .y = 0 };
    const x = parseNumber(first);
    if (it.next()) |second| return .{ .x = x, .y = parseNumber(second) };
    return .{ .x = x, .y = x };
}

fn parseNumber(text: []const u8) f32 {
    var t = zstd.mem.trim(u8, text, " \t");
    if (endsWithIgnoreCase(t, "deg")) t = t[0 .. t.len - 3];
    if (endsWithIgnoreCase(t, "%")) {
        t = t[0 .. t.len - 1];
        const n = zstd.fmt.parseFloat(f32, t) catch return 0;
        return n / 100.0;
    }
    return zstd.fmt.parseFloat(f32, t) catch 0;
}

fn parseAtMs(text: []const u8, span_ms: i64, origin_ms: i64) i64 {
    const t = zstd.mem.trim(u8, text, " \t");
    if (zstd.mem.endsWith(u8, t, "%")) {
        const n = zstd.fmt.parseFloat(f32, t[0 .. t.len - 1]) catch 0;
        const offset: i64 = @intFromFloat(n / 100.0 * @as(f32, @floatFromInt(span_ms)));
        return origin_ms + offset;
    }
    return origin_ms + parseDurationMs(t);
}

const ChannelAccum = struct {
    channel: animation.Channel,
    keys: zstd.ArrayList(animation.Keyframe),
};

fn takeTagBlock(hay: []const u8, name: []const u8, from: usize) ?struct { start: usize, end: usize, tag: []const u8, inner: []const u8 } {
    const needle_open = if (zstd.mem.eql(u8, name, "animate")) "<animate" else if (zstd.mem.eql(u8, name, "soundtrack")) "<soundtrack" else "<slide";
    const rel = indexOfIgnoreCase(hay[from..], needle_open) orelse return null;
    const start = from + rel;
    const tag_end = zstd.mem.indexOfScalarPos(u8, hay, start, '>') orelse return null;
    const tag = hay[start .. tag_end + 1];
    const self_close = tag_end > start and hay[tag_end - 1] == '/';
    if (self_close) {
        return .{ .start = start, .end = tag_end + 1, .tag = tag, .inner = "" };
    }
    const close_name = if (zstd.mem.eql(u8, name, "animate")) "</animate>" else "</soundtrack>";
    const close_rel = indexOfIgnoreCase(hay[tag_end + 1 ..], close_name) orelse {
        return .{ .start = start, .end = tag_end + 1, .tag = tag, .inner = "" };
    };
    const inner = hay[tag_end + 1 .. tag_end + 1 + close_rel];
    return .{ .start = start, .end = tag_end + 1 + close_rel + close_name.len, .tag = tag, .inner = inner };
}

fn stripTags(allocator: zstd.mem.Allocator, inner: []const u8) !struct { body: []const u8, animate: []u8, cues: []u8 } {
    var body: zstd.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var i: usize = 0;
    var animate_buf: zstd.ArrayList(u8) = .empty;
    var cue_buf: zstd.ArrayList(u8) = .empty;
    while (i < inner.len) {
        if (takeTagBlock(inner, "animate", i)) |block| {
            if (block.start == i) {
                try animate_buf.appendSlice(allocator, inner[block.start..block.end]);
                try animate_buf.append(allocator, '\n');
                i = block.end;
                continue;
            }
        }
        if (takeTagBlock(inner, "soundtrack", i)) |block| {
            if (block.start == i) {
                try cue_buf.appendSlice(allocator, inner[block.start..block.end]);
                try cue_buf.append(allocator, '\n');
                i = block.end;
                continue;
            }
        }
        const next_a = indexOfIgnoreCase(inner[i..], "<animate");
        const next_s = indexOfIgnoreCase(inner[i..], "<soundtrack");
        var next = inner.len;
        if (next_a) |r| next = @min(next, i + r);
        if (next_s) |r| next = @min(next, i + r);
        try body.appendSlice(allocator, inner[i..next]);
        i = next;
        if (i < inner.len and inner[i] == '<') {
            if (takeTagBlock(inner, "animate", i) != null or takeTagBlock(inner, "soundtrack", i) != null) continue;
            try body.append(allocator, inner[i]);
            i += 1;
        }
    }
    return .{
        .body = zstd.mem.trim(u8, try body.toOwnedSlice(allocator), " \n\r\t"),
        .animate = try animate_buf.toOwnedSlice(allocator),
        .cues = try cue_buf.toOwnedSlice(allocator),
    };
}

fn slugify(allocator: zstd.mem.Allocator, text: []const u8) ![]const u8 {
    var out: zstd.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var prev_dash = false;
    for (text) |c| {
        const lower = zstd.ascii.toLower(c);
        if (zstd.ascii.isAlphanumeric(lower)) {
            try out.append(allocator, lower);
            prev_dash = false;
        } else if (out.items.len > 0 and !prev_dash) {
            try out.append(allocator, '-');
            prev_dash = true;
        }
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(allocator, "node");
    return out.toOwnedSlice(allocator);
}

const Block = struct {
    kind: enum { heading, paragraph, image, table, mermaid, markdown },
    level: u8 = 1,
    id: []const u8,
    text: []const u8,
    src: []const u8 = "",
    source: []const u8 = "",
    headers: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    fill: []const u8 = "",
    font_family: []const u8 = "",
    font_size: f32 = 0,
    font_weight: u16 = 0,
    style: []const u8 = "",
    media_kind: []const u8 = "",
};

const Trailing = struct {
    body: []const u8,
    id: ?[]const u8 = null,
    color: ?[]const u8 = null,
    font: ?[]const u8 = null,
    size: ?[]const u8 = null,
    weight: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    style: ?[]const u8 = null,
};

fn parseFontSize(text: []const u8) f32 {
    var t = zstd.mem.trim(u8, text, " \t");
    if (endsWithIgnoreCase(t, "px")) t = zstd.mem.trim(u8, t[0 .. t.len - 2], " \t");
    return zstd.fmt.parseFloat(f32, t) catch 0;
}

fn parseWeight(text: []const u8) u16 {
    const t = zstd.mem.trim(u8, text, " \t");
    if (zstd.ascii.eqlIgnoreCase(t, "bold")) return 700;
    if (zstd.ascii.eqlIgnoreCase(t, "normal")) return 400;
    if (zstd.ascii.eqlIgnoreCase(t, "light")) return 300;
    return zstd.fmt.parseInt(u16, t, 10) catch 0;
}

fn isVideoSrc(src: []const u8, kind: ?[]const u8) bool {
    if (kind) |k| {
        if (zstd.ascii.eqlIgnoreCase(k, "video")) return true;
    }
    const ext = fs_ext(src);
    const video_exts = [_][]const u8{ ".mp4", ".webm", ".mov", ".m4v", ".ogv" };
    for (video_exts) |candidate| {
        if (zstd.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return zstd.mem.indexOf(u8, src, "user-attachments/assets") != null;
}

fn fs_ext(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        switch (path[i]) {
            '/', '\\' => return "",
            '.' => return path[i..],
            else => {},
        }
    }
    return "";
}

fn trailingAttrs(text: []const u8) Trailing {
    var out = Trailing{ .body = zstd.mem.trim(u8, text, " \t") };
    const t = out.body;
    if (t.len < 3 or t[t.len - 1] != '}') return out;
    const brace = zstd.mem.lastIndexOfScalar(u8, t, '{') orelse return out;
    const inner = t[brace + 1 .. t.len - 1];
    out.body = zstd.mem.trim(u8, t[0..brace], " \t");
    if (inner.len > 1 and inner[0] == '#' and zstd.mem.indexOfScalar(u8, inner, '=') == null) {
        out.id = zstd.mem.trim(u8, inner[1..], " \t");
        return out;
    }
    out.id = attrValue(inner, "id");
    out.color = attrValue(inner, "color") orelse attrValue(inner, "fill");
    out.font = attrValue(inner, "font") orelse attrValue(inner, "font-family");
    out.size = attrValue(inner, "size") orelse attrValue(inner, "font-size");
    out.weight = attrValue(inner, "weight") orelse attrValue(inner, "font-weight");
    out.kind = attrValue(inner, "kind") orelse attrValue(inner, "type");
    out.style = attrValue(inner, "style");
    return out;
}

fn isTableSep(line: []const u8) bool {
    const t = zstd.mem.trim(u8, line, " \t");
    if (t.len < 3) return false;
    var saw_pipe = false;
    var saw_dash = false;
    for (t) |c| {
        switch (c) {
            '|', ' ', '-', ':' => {
                if (c == '|') saw_pipe = true;
                if (c == '-') saw_dash = true;
            },
            else => return false,
        }
    }
    return saw_pipe and saw_dash;
}

fn splitRow(allocator: zstd.mem.Allocator, line: []const u8) ![]const []const u8 {
    var cells: zstd.ArrayList([]const u8) = .empty;
    errdefer cells.deinit(allocator);
    var t = zstd.mem.trim(u8, line, " \t");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    var it = zstd.mem.splitScalar(u8, t, '|');
    while (it.next()) |cell| {
        try cells.append(allocator, zstd.mem.trim(u8, cell, " \t"));
    }
    return cells.toOwnedSlice(allocator);
}

fn parseBlocks(allocator: zstd.mem.Allocator, body: []const u8) ![]Block {
    var blocks: zstd.ArrayList(Block) = .empty;
    errdefer blocks.deinit(allocator);
    var auto: usize = 0;
    var lines = zstd.mem.splitScalar(u8, body, '\n');
    var pending: zstd.ArrayList([]const u8) = .empty;
    defer pending.deinit(allocator);

    const flush_para = struct {
        fn call(
            a: zstd.mem.Allocator,
            list: *zstd.ArrayList(Block),
            buf: *zstd.ArrayList([]const u8),
            auto_id: *usize,
        ) !void {
            if (buf.items.len == 0) return;
            var text: zstd.ArrayList(u8) = .empty;
            for (buf.items, 0..) |line, i| {
                if (i > 0) try text.append(a, '\n');
                try text.appendSlice(a, line);
            }
            auto_id.* += 1;
            const id = try zstd.fmt.allocPrint(a, "p-{d}", .{auto_id.*});
            try list.append(a, .{
                .kind = .paragraph,
                .id = id,
                .text = try text.toOwnedSlice(a),
            });
            buf.clearRetainingCapacity();
        }
    }.call;

    while (lines.next()) |line_raw| {
        const line = zstd.mem.trim(u8, line_raw, " \t\r");
        const trimmed = zstd.mem.trim(u8, line, " \t");

        if (zstd.mem.startsWith(u8, trimmed, "```")) {
            try flush_para(allocator, &blocks, &pending, &auto);
            const info = zstd.mem.trim(u8, trimmed[3..], " \t");
            var fence: zstd.ArrayList(u8) = .empty;
            while (lines.next()) |inner| {
                const t = zstd.mem.trim(u8, inner, "\r");
                if (zstd.mem.startsWith(u8, zstd.mem.trim(u8, t, " \t"), "```")) break;
                if (fence.items.len > 0) try fence.append(allocator, '\n');
                try fence.appendSlice(allocator, t);
            }
            auto += 1;
            const source = try fence.toOwnedSlice(allocator);
            if (zstd.ascii.eqlIgnoreCase(info, "mermaid")) {
                try blocks.append(allocator, .{
                    .kind = .mermaid,
                    .id = try zstd.fmt.allocPrint(allocator, "mermaid-{d}", .{auto}),
                    .text = "",
                    .source = source,
                });
            } else {
                try blocks.append(allocator, .{
                    .kind = .markdown,
                    .id = try zstd.fmt.allocPrint(allocator, "code-{d}", .{auto}),
                    .text = source,
                });
            }
            continue;
        }

        if (trimmed.len > 0 and trimmed[0] == '|') {
            try flush_para(allocator, &blocks, &pending, &auto);
            var table_lines: zstd.ArrayList([]const u8) = .empty;
            try table_lines.append(allocator, trimmed);
            while (lines.next()) |next_raw| {
                const next = zstd.mem.trim(u8, zstd.mem.trim(u8, next_raw, " \r"), " \t");
                if (next.len == 0 or next[0] != '|') {
                    // put back by... we can't easily put back. If not a table line, treat as new.
                    if (next.len != 0) try pending.append(allocator, next);
                    break;
                }
                try table_lines.append(allocator, next);
            }
            if (table_lines.items.len >= 2) {
                const headers = try splitRow(allocator, table_lines.items[0]);
                var data_start: usize = 1;
                if (isTableSep(table_lines.items[1])) data_start = 2;
                var rows: zstd.ArrayList([]const []const u8) = .empty;
                for (table_lines.items[data_start..]) |row_line| {
                    try rows.append(allocator, try splitRow(allocator, row_line));
                }
                auto += 1;
                try blocks.append(allocator, .{
                    .kind = .table,
                    .id = try zstd.fmt.allocPrint(allocator, "table-{d}", .{auto}),
                    .text = "",
                    .headers = headers,
                    .rows = try rows.toOwnedSlice(allocator),
                });
            }
            continue;
        }

        if (trimmed.len == 0) {
            try flush_para(allocator, &blocks, &pending, &auto);
            continue;
        }

        if (trimmed[0] == '#') {
            try flush_para(allocator, &blocks, &pending, &auto);
            var level: u8 = 0;
            while (level < trimmed.len and trimmed[level] == '#') level += 1;
            const rest = trailingAttrs(zstd.mem.trim(u8, trimmed[level..], " \t"));
            auto += 1;
            const id = rest.id orelse if (level == 1)
                try allocator.dupe(u8, "title")
            else
                try slugify(allocator, rest.body);
            try blocks.append(allocator, .{
                .kind = .heading,
                .level = level,
                .id = id,
                .text = rest.body,
                .fill = rest.color orelse "",
                .font_family = rest.font orelse "",
                .font_size = if (rest.size) |s| parseFontSize(s) else 0,
                .font_weight = if (rest.weight) |w| parseWeight(w) else 0,
                .style = rest.style orelse "",
            });
            continue;
        }

        if (zstd.mem.startsWith(u8, trimmed, "![")) {
            try flush_para(allocator, &blocks, &pending, &auto);
            const rest = trailingAttrs(trimmed);
            const bang = rest.body;
            const src_start = zstd.mem.indexOfScalar(u8, bang, '(') orelse continue;
            const src_end = zstd.mem.indexOfScalarPos(u8, bang, src_start + 1, ')') orelse continue;
            var src = zstd.mem.trim(u8, bang[src_start + 1 .. src_end], " \t");
            if (zstd.mem.indexOfScalar(u8, src, ' ')) |sp| src = src[0..sp];
            const alt_end = zstd.mem.indexOfScalar(u8, bang, ']') orelse 2;
            const alt = bang[2..alt_end];
            auto += 1;
            try blocks.append(allocator, .{
                .kind = .image,
                .id = rest.id orelse try slugify(allocator, if (alt.len > 0) alt else src),
                .text = alt,
                .src = src,
                .fill = rest.color orelse "",
                .style = rest.style orelse "",
                .media_kind = rest.kind orelse if (isVideoSrc(src, rest.kind)) "video" else "image",
            });
            continue;
        }

        try pending.append(allocator, trimmed);
    }
    try flush_para(allocator, &blocks, &pending, &auto);
    return blocks.toOwnedSlice(allocator);
}

const Theme = struct {
    fill: []const u8 = "#eef1f7",
    background: []const u8 = "#0a0d14",
    font: []const u8 = "Bricolage Grotesque, Inter, system-ui, sans-serif",
};

fn headingSize(level: u8) f32 {
    return switch (level) {
        1 => 72,
        2 => 48,
        3 => 32,
        else => 24,
    };
}

fn countWrappedLines(text: []const u8, max_w: f32, size: f32) usize {
    const col_w = @max(size * 0.58, 8);
    const cols = @max(@as(usize, 1), @as(usize, @intFromFloat(max_w / col_w)));
    var lines: usize = 0;
    var iter = zstd.mem.splitScalar(u8, text, '\n');
    var any = false;
    while (iter.next()) |raw| {
        any = true;
        const line = zstd.mem.trim(u8, raw, " \t");
        if (line.len == 0) {
            lines += 1;
            continue;
        }
        lines += @max(@as(usize, 1), (line.len + cols - 1) / cols);
    }
    return if (any) @max(lines, 1) else 1;
}

fn isMediaBlock(block: Block) bool {
    return block.kind == .image;
}

fn blockKindName(block: Block) []const u8 {
    return switch (block.kind) {
        .heading => "text",
        .paragraph, .markdown => "markdown",
        .table => "table",
        .mermaid => "mermaid",
        .image => if (isVideoSrc(block.src, if (block.media_kind.len > 0) block.media_kind else null))
            "video"
        else
            "image",
    };
}

fn preferredHeight(block: Block, max_w: f32, font_size: f32) f32 {
    const line = font_size * 1.35;
    return switch (block.kind) {
        .heading => line * @as(f32, @floatFromInt(countWrappedLines(block.text, max_w, font_size))),
        .paragraph => line * @as(f32, @floatFromInt(countWrappedLines(block.text, max_w, font_size))),
        .markdown => @max(line * @as(f32, @floatFromInt(countWrappedLines(block.text, max_w, font_size))), 80),
        .table => 44 * @as(f32, @floatFromInt(@max(block.rows.len + 1, 1))) + 16,
        .mermaid => 420,
        .image => if (zstd.mem.eql(u8, blockKindName(block), "video")) 480 else 360,
    };
}

fn layoutBlocks(
    allocator: zstd.mem.Allocator,
    blocks: []const Block,
    width: u32,
    height: u32,
    theme: Theme,
) ![]deck_mod.Node {
    var nodes: zstd.ArrayList(deck_mod.Node) = .empty;
    errdefer nodes.deinit(allocator);
    const pad: f32 = 96;
    const gap: f32 = 22;
    const max_w = @as(f32, @floatFromInt(width)) - pad * 2;
    const content_h = @as(f32, @floatFromInt(height)) - pad * 2;
    const n = blocks.len;
    if (n == 0) return nodes.toOwnedSlice(allocator);

    var heights = try allocator.alloc(f32, n);
    var sizes = try allocator.alloc(f32, n);
    var weights = try allocator.alloc(u16, n);
    var flex = try allocator.alloc(bool, n);

    var fixed: f32 = 0;
    var flex_n: usize = 0;
    for (blocks, 0..) |block, i| {
        var font_size: f32 = 28;
        var weight: u16 = 400;
        if (block.kind == .heading) {
            font_size = headingSize(block.level);
            weight = 700;
        }
        if (block.font_size > 0) font_size = block.font_size;
        if (block.font_weight > 0) weight = block.font_weight;
        sizes[i] = font_size;
        weights[i] = weight;
        flex[i] = isMediaBlock(block);
        heights[i] = preferredHeight(block, max_w, font_size);
        if (flex[i]) flex_n += 1 else fixed += heights[i];
    }

    const gaps = @as(f32, @floatFromInt(n - 1)) * gap;
    if (flex_n > 0) {
        const min_flex: f32 = 140;
        const need = min_flex * @as(f32, @floatFromInt(flex_n));
        if (fixed + gaps + need > content_h and fixed > 0) {
            const scale = @max(0.6, (content_h - gaps - need) / fixed);
            for (heights, flex, sizes) |*h, is_flex, *size| {
                if (!is_flex) {
                    h.* *= scale;
                    size.* *= scale;
                }
            }
            fixed *= scale;
        }
        const leftover = @max(40, content_h - fixed - gaps);
        const each = leftover / @as(f32, @floatFromInt(flex_n));
        for (heights, flex) |*h, is_flex| {
            if (is_flex) h.* = @max(80, each);
        }
    } else if (fixed + gaps > content_h and fixed > 0) {
        const scale = @max(0.55, (content_h - gaps) / fixed);
        for (heights, sizes) |*h, *size| {
            h.* *= scale;
            size.* *= scale;
        }
    }

    var y: f32 = pad;
    const bottom = @as(f32, @floatFromInt(height)) - pad;
    var saw_title = false;
    for (blocks, 0..) |block, i| {
        var id = block.id;
        if (block.kind == .heading and block.level == 1) {
            if (saw_title and zstd.mem.eql(u8, id, "title")) {
                id = try slugify(allocator, block.text);
            }
            saw_title = true;
        }
        var h = heights[i];
        if (y + h > bottom) h = @max(0, bottom - y);
        if (h < 10) continue;

        const kind = blockKindName(block);
        try nodes.append(allocator, .{
            .id = id,
            .kind = kind,
            .bounds = .{ .x = pad, .y = y, .w = max_w, .h = h },
            .z = @intCast(nodes.items.len),
            .src = block.src,
            .text = block.text,
            .fill = if (block.fill.len > 0) block.fill else theme.fill,
            .headers = block.headers,
            .rows = block.rows,
            .source = "",
            .clip = true,
            .font = .{
                .family = if (block.font_family.len > 0) block.font_family else theme.font,
                .size_px = sizes[i],
                .weight = weights[i],
            },
            .style = block.style,
        });
        if (block.kind == .mermaid) {
            nodes.items[nodes.items.len - 1].source = block.source;
            nodes.items[nodes.items.len - 1].text = "";
        }
        y += h + gap;
    }
    return nodes.toOwnedSlice(allocator);
}

fn parseKeyframesFromInner(
    allocator: zstd.mem.Allocator,
    inner: []const u8,
    origin_ms: i64,
    span_ms: i64,
    default_ease: []const u8,
) !struct {
    translate: ?RangePair,
    scale: ?RangePair,
    rotate: ?RangeF,
    opacity: ?RangeF,
    keys: zstd.ArrayList(Kf),
} {
    var keys: zstd.ArrayList(Kf) = .empty;

    var translate: ?RangePair = null;
    var scale: ?RangePair = null;
    var rotate: ?RangeF = null;
    var opacity: ?RangeF = null;

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and inner[i] != '<') i += 1;
        if (i >= inner.len) break;
        const tag_end = zstd.mem.indexOfScalarPos(u8, inner, i, '>') orelse break;
        const tag = inner[i .. tag_end + 1];
        i = tag_end + 1;

        const is_keyframe = startsWithIgnoreCase(tag, "<keyframe");
        const is_translate = startsWithIgnoreCase(tag, "<translate");
        const is_scale = startsWithIgnoreCase(tag, "<scale");
        const is_rotate = startsWithIgnoreCase(tag, "<rotate");
        const is_opacity = startsWithIgnoreCase(tag, "<opacity");
        if (!(is_keyframe or is_translate or is_scale or is_rotate or is_opacity)) continue;

        if (is_keyframe) {
            const at = attrValue(tag, "at") orelse "0%";
            try keys.append(allocator, .{
                .t_ms = parseAtMs(at, span_ms, origin_ms),
                .translate = if (attrValue(tag, "translate")) |v| parsePair(v) else null,
                .scale = if (attrValue(tag, "scale")) |v| parsePair(v) else null,
                .rotate = if (attrValue(tag, "rotate")) |v| parseNumber(v) else null,
                .opacity = if (attrValue(tag, "opacity")) |v| parseNumber(v) else null,
                .ease = attrValue(tag, "ease") orelse default_ease,
            });
            continue;
        }
        const from = attrValue(tag, "from");
        const to = attrValue(tag, "to");
        if (is_translate and from != null and to != null) {
            translate = .{ .from = parsePair(from.?), .to = parsePair(to.?) };
        } else if (is_scale and from != null and to != null) {
            scale = .{ .from = parsePair(from.?), .to = parsePair(to.?) };
        } else if (is_rotate and from != null and to != null) {
            rotate = .{ .from = parseNumber(from.?), .to = parseNumber(to.?) };
        } else if (is_opacity and from != null and to != null) {
            opacity = .{ .from = parseNumber(from.?), .to = parseNumber(to.?) };
        }
    }
    return .{ .translate = translate, .scale = scale, .rotate = rotate, .opacity = opacity, .keys = keys };
}

fn appendTrack(
    allocator: zstd.mem.Allocator,
    tracks: *zstd.ArrayList(deck_mod.Track),
    target: []const u8,
    channel: []const u8,
    t0: i64,
    t1: i64,
    from_x: f32,
    from_y: f32,
    to_x: f32,
    to_y: f32,
    ease: []const u8,
) !void {
    const v0 = try allocator.dupe(f32, &.{ from_x, from_y });
    const v1 = try allocator.dupe(f32, &.{ to_x, to_y });
    const keys = try allocator.dupe(deck_mod.Keyframe, &.{
        .{ .t_ms = t0, .value = v0, .ease = ease },
        .{ .t_ms = t1, .value = v1, .ease = ease },
    });
    try tracks.append(allocator, .{ .target = target, .channel = channel, .keyframes = keys });
}

fn compileAnimates(
    allocator: zstd.mem.Allocator,
    blob: []const u8,
    slide_start: i64,
    slide_dur: i64,
) ![]deck_mod.Track {
    var tracks: zstd.ArrayList(deck_mod.Track) = .empty;
    errdefer tracks.deinit(allocator);
    var from: usize = 0;
    while (takeTagBlock(blob, "animate", from)) |block| {
        from = block.end;
        const target = attrValue(block.tag, "target") orelse "title";
        const ease = attrValue(block.tag, "ease") orelse "linear";
        var origin = slide_start;
        var span: i64 = 800;
        if (attrValue(block.tag, "from")) |v| origin = slide_start + parseDurationMs(v);
        if (attrValue(block.tag, "to")) |v| {
            const abs = slide_start + parseDurationMs(v);
            span = abs - origin;
        } else if (attrValue(block.tag, "dur")) |v| {
            span = parseDurationMs(v);
        }
        if (span <= 0) span = 800;
        _ = slide_dur;

        const parsed = try parseKeyframesFromInner(allocator, block.inner, origin, span, ease);
        if (parsed.keys.items.len > 0) {
            const channels = [_][]const u8{ "translate", "scale", "rotate", "opacity" };
            for (channels) |ch| {
                var kfs: zstd.ArrayList(deck_mod.Keyframe) = .empty;
                for (parsed.keys.items) |kf| {
                    const pair: ?Pair = switch (ch[0]) {
                        't' => kf.translate,
                        's' => kf.scale,
                        'r' => if (kf.rotate) |r| .{ .x = r, .y = 0 } else null,
                        else => if (kf.opacity) |o| .{ .x = o, .y = 0 } else null,
                    };
                    if (pair) |p| {
                        const val = if (ch[0] == 't' or ch[0] == 's')
                            try allocator.dupe(f32, &.{ p.x, p.y })
                        else
                            try allocator.dupe(f32, &.{p.x});
                        try kfs.append(allocator, .{ .t_ms = kf.t_ms, .value = val, .ease = kf.ease });
                    }
                }
                if (kfs.items.len > 0) {
                    try tracks.append(allocator, .{
                        .target = target,
                        .channel = ch,
                        .keyframes = try kfs.toOwnedSlice(allocator),
                    });
                } else {
                    kfs.deinit(allocator);
                }
            }
        } else {
            if (parsed.translate) |tr| {
                try appendTrack(allocator, &tracks, target, "translate", origin, origin + span, tr.from.x, tr.from.y, tr.to.x, tr.to.y, ease);
            }
            if (parsed.scale) |sc| {
                try appendTrack(allocator, &tracks, target, "scale", origin, origin + span, sc.from.x, sc.from.y, sc.to.x, sc.to.y, ease);
            }
            if (parsed.rotate) |rt| {
                try appendTrack(allocator, &tracks, target, "rotate", origin, origin + span, rt.from, 0, rt.to, 0, ease);
            }
            if (parsed.opacity) |op| {
                try appendTrack(allocator, &tracks, target, "opacity", origin, origin + span, op.from, 0, op.to, 0, ease);
            }
        }
    }
    return tracks.toOwnedSlice(allocator);
}

fn compileCues(
    allocator: zstd.mem.Allocator,
    blob: []const u8,
    slide_start: i64,
) ![]deck_mod.Cue {
    var cues: zstd.ArrayList(deck_mod.Cue) = .empty;
    errdefer cues.deinit(allocator);
    var from: usize = 0;
    while (takeTagBlock(blob, "soundtrack", from)) |block| {
        from = block.end;
        const src = attrValue(block.tag, "src") orelse continue;
        const at = attrValue(block.tag, "at") orelse "0ms";
        const vol = attrValue(block.tag, "volume") orelse "1";
        try cues.append(allocator, .{
            .url = src,
            .start_ms = slide_start + parseDurationMs(at),
            .volume = parseNumber(vol),
        });
    }
    return cues.toOwnedSlice(allocator);
}

pub const CompileOpts = struct {
    slug: []const u8,
    path: []const u8,
};

pub fn compile(allocator: zstd.mem.Allocator, source: []const u8, opts: CompileOpts) !deck_mod.Deck {
    const fm = stripFrontmatter(source);
    const raw_slides = try collectSlides(allocator, fm.body);
    if (raw_slides.len == 0) return error.NoSlides;

    var slides: zstd.ArrayList(deck_mod.Slide) = .empty;
    errdefer slides.deinit(allocator);

    var cursor: i64 = 0;
    var title = fm.title;
    for (raw_slides) |raw| {
        const stripped = try stripTags(allocator, raw.inner);
        const blocks = try parseBlocks(allocator, stripped.body);
        if (title.len == 0) {
            for (blocks) |b| {
                if (b.kind == .heading and b.level == 1) {
                    title = b.text;
                    break;
                }
            }
        }
        const nodes = try layoutBlocks(allocator, blocks, fm.width, fm.height, .{
            .fill = if (raw.color.len > 0) raw.color else fm.color,
            .background = if (raw.background.len > 0) raw.background else fm.background,
            .font = if (raw.font.len > 0) raw.font else fm.font,
        });
        const tracks = try compileAnimates(allocator, stripped.animate, cursor, raw.duration_ms);
        const cues = try compileCues(allocator, stripped.cues, cursor);
        const trans_kind = carousel.Kind.parse(raw.transition);
        try slides.append(allocator, .{
            .id = raw.id,
            .start_ms = cursor,
            .duration_ms = if (raw.duration_ms > 0) raw.duration_ms else 4000,
            .transition = .{
                .kind = trans_kind.json(),
                .duration_ms = if (trans_kind == .none) 0 else 350,
            },
            .canvas = .{
                .width = fm.width,
                .height = fm.height,
                .background = if (raw.background.len > 0) raw.background else fm.background,
            },
            .nodes = nodes,
            .tracks = tracks,
            .cues = cues,
        });
        cursor += if (raw.duration_ms > 0) raw.duration_ms else 4000;
    }

    var soundtrack: ?deck_mod.Soundtrack = null;
    if (fm.soundtrack.len > 0) {
        soundtrack = .{ .url = try allocator.dupe(u8, fm.soundtrack) };
    }

    const owned_title = if (title.len > 0) title else opts.slug;
    return .{
        .slug = opts.slug,
        .title = try allocator.dupe(u8, owned_title),
        .path = opts.path,
        .fps = fm.fps,
        .size = .{ .w = fm.width, .h = fm.height },
        .soundtrack = soundtrack,
        .image = try allocator.dupe(u8, fm.image),
        .slides = try slides.toOwnedSlice(allocator),
    };
}

const testing = zstd.testing;

test "parseDurationMs understands s and ms" {
    try testing.expectEqual(@as(i64, 4000), parseDurationMs("4s"));
    try testing.expectEqual(@as(i64, 800), parseDurationMs("800ms"));
    try testing.expectEqual(@as(i64, 1200), parseDurationMs("1.2s"));
}

test "compile two slides with keyframes and table" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\---
        \\title: Demo Talk
        \\fps: 30
        \\size: 1920x1080
        \\soundtrack: ./audio/talk.mp3
        \\image: '![image](./cover.webp)'
        \\---
        \\
        \\<slide id="open" duration="4s" transition="fade">
        \\# Opening
        \\
        \\Hello **world**
        \\
        \\<animate target="title" from="0ms" to="800ms" ease="linear">
        \\  <keyframe at="0%" translate="0,40" scale="0.9" rotate="0" opacity="0"/>
        \\  <keyframe at="100%" translate="0,0" scale="1" rotate="0" opacity="1"/>
        \\</animate>
        \\</slide>
        \\
        \\<slide id="idea" duration="6s">
        \\![diagram](./diagram.png){id="dia"}
        \\
        \\<animate target="dia" dur="700ms">
        \\  <translate from="80,0" to="0,0"/>
        \\  <scale from="0.85" to="1"/>
        \\</animate>
        \\
        \\<soundtrack src="./audio/whoosh.mp3" at="200ms" volume="0.4"/>
        \\
        \\| Col A | Col B |
        \\| --- | --- |
        \\| 1 | 2 |
        \\
        \\```mermaid
        \\flowchart LR
        \\  a --> b
        \\```
        \\</slide>
    ;

    const compiled = try compile(a, src, .{ .slug = "demo", .path = "demo.md" });
    try testing.expectEqualStrings("![image](./cover.webp)", compiled.image);
    try testing.expectEqual(@as(usize, 2), compiled.slides.len);
    try testing.expectEqualStrings("open", compiled.slides[0].id);
    try testing.expectEqualStrings("idea", compiled.slides[1].id);
    try testing.expectEqual(@as(i64, 0), compiled.slides[0].start_ms);
    try testing.expectEqual(@as(i64, 4000), compiled.slides[1].start_ms);
    try testing.expect(compiled.soundtrack != null);
    try testing.expectEqualStrings("./audio/talk.mp3", compiled.soundtrack.?.url);

    var has_title = false;
    for (compiled.slides[0].nodes) |node| {
        if (zstd.mem.eql(u8, node.id, "title")) has_title = true;
    }
    try testing.expect(has_title);

    const xf_tracks = try deck_mod.compileTracks(testing.allocator, compiled.slides[0].tracks);
    defer deck_mod.freeCompiledTracks(testing.allocator, xf_tracks);
    const mid = animation.sampleTransform(xf_tracks, "title", 400);
    try testing.expect(mid.ty > 19 and mid.ty < 21);
    try testing.expect(mid.opacity > 0.49 and mid.opacity < 0.51);

    var saw_table = false;
    var saw_mermaid = false;
    var saw_dia = false;
    for (compiled.slides[1].nodes) |node| {
        if (zstd.mem.eql(u8, node.kind, "table")) {
            saw_table = true;
            try testing.expectEqual(@as(usize, 2), node.headers.len);
        }
        if (zstd.mem.eql(u8, node.kind, "mermaid")) {
            saw_mermaid = true;
            try testing.expect(zstd.mem.indexOf(u8, node.source, "flowchart") != null);
        }
        if (zstd.mem.eql(u8, node.id, "dia")) saw_dia = true;
    }
    try testing.expect(saw_table);
    try testing.expect(saw_mermaid);
    try testing.expect(saw_dia);
    try testing.expectEqual(@as(usize, 1), compiled.slides[1].cues.len);
}

test "compile skips files without slides" {
    try testing.expect(!containsSlide("# Hello\n\nNo slides here.\n"));
    try testing.expect(!containsSlide("Mentions of `<slide>` in prose are not decks.\n"));
    try testing.expect(containsSlide("<slide id=\"open\"># Hi</slide>\n"));
    try testing.expect(containsOrphanAnimate("<animate target=\"x\"></animate>"));
}

test "compile reads color font and video kind" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\---
        \\title: Styled
        \\color: '#ccddee'
        \\background: '#111111'
        \\font: 'Inter, sans-serif'
        \\---
        \\
        \\<slide id="open" background="#0b1020">
        \\# Hello {color="#f6c244" font="Georgia, serif" size="64"}
        \\
        \\![clip](https://github.com/user-attachments/assets/abc){kind="video" id="hero"}
        \\</slide>
    ;
    const compiled = try compile(arena.allocator(), src, .{ .slug = "styled", .path = "styled.md" });
    try testing.expectEqualStrings("#0b1020", compiled.slides[0].canvas.background);
    var saw_title = false;
    var saw_video = false;
    for (compiled.slides[0].nodes) |node| {
        if (zstd.mem.eql(u8, node.id, "title")) {
            saw_title = true;
            try testing.expectEqualStrings("#f6c244", node.fill);
            try testing.expectEqualStrings("Georgia, serif", node.font.family);
            try testing.expectEqual(@as(f32, 64), node.font.size_px);
        }
        if (zstd.mem.eql(u8, node.id, "hero")) {
            saw_video = true;
            try testing.expectEqualStrings("video", node.kind);
        }
    }
    try testing.expect(saw_title);
    try testing.expect(saw_video);
}

test "compile hercules architecture fixture" {
    const fs = @import("../../compat_fs.zig");
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = fs.cwd().readFileAlloc(
        testing.allocator,
        "pages/blog/projects/hercules/architecture.md",
        2 * 1024 * 1024,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(src);
    const compiled = try compile(arena.allocator(), src, .{
        .slug = "blog/projects/hercules/architecture",
        .path = "pages/blog/projects/hercules/architecture.md",
    });
    try testing.expect(compiled.slides.len >= 14);

    const expected = [_][]const u8{
        "title",
        "roadmap",
        "the-paper",
        "reading-the-paper",
        "why-go",
        "master-server",
        "chunk-server",
        "locking-and-leasing",
        "failure-detection",
        "data-integrity",
        "client-sdk",
        "field-notes",
        "summary",
        "closing",
    };
    try testing.expectEqual(expected.len, compiled.slides.len);
    for (expected, compiled.slides) |id, slide| {
        try testing.expectEqualStrings(id, slide.id);
    }

    var has_title_track = false;
    for (compiled.slides[0].tracks) |track| {
        if (zstd.mem.eql(u8, track.target, "title")) has_title_track = true;
    }
    try testing.expect(has_title_track);

    const xf_tracks = try deck_mod.compileTracks(testing.allocator, compiled.slides[0].tracks);
    defer deck_mod.freeCompiledTracks(testing.allocator, xf_tracks);
    const mid = animation.sampleTransform(xf_tracks, "title", 400);
    try testing.expect(mid.ty > 0);

    var saw_locks = false;
    const lock = compiled.slides[7];
    try testing.expectEqualStrings("locking-and-leasing", lock.id);
    for (lock.nodes, 0..) |node, i| {
        try testing.expect(node.bounds.y >= 0);
        try testing.expect(node.bounds.y + node.bounds.h <= 1080 + 0.5);
        if (i > 0) {
            const prev = lock.nodes[i - 1];
            try testing.expect(prev.bounds.y + prev.bounds.h <= node.bounds.y + 1);
        }
        if (zstd.mem.indexOf(u8, node.text, "Namespace locks") != null) saw_locks = true;
    }
    try testing.expect(saw_locks);

    for (compiled.slides[0].nodes) |node| {
        if (!zstd.mem.eql(u8, node.id, "title")) continue;
        try testing.expect(node.bounds.h >= 140);
    }

    const json = try deck_mod.serializeDeck(testing.allocator, compiled);
    defer testing.allocator.free(json);
    var round_arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer round_arena.deinit();
    const round = try deck_mod.deserializeDeck(round_arena.allocator(), json);
    try testing.expectEqual(compiled.slides.len, round.slides.len);
    try testing.expectEqualStrings(compiled.slides[0].id, round.slides[0].id);
}
