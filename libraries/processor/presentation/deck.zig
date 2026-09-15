const zstd = @import("std");
const common = @import("common");
const animation = @import("renderer/animation.zig");
const carousel = @import("renderer/carousel.zig");

pub const version: u32 = 1;

pub const Size = struct {
    w: u32 = 1920,
    h: u32 = 1080,
};

pub const Font = struct {
    family: []const u8 = "Inter, system-ui, sans-serif",
    size_px: f32 = 32,
    weight: u16 = 400,
};

pub const Origin = struct {
    x: f32,
    y: f32,
};

pub const Bounds = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

pub const Node = struct {
    id: []const u8,
    kind: []const u8,
    bounds: Bounds,
    z: i32 = 0,
    src: []const u8 = "",
    text: []const u8 = "",
    fill: []const u8 = "#eef1f7",
    stroke: []const u8 = "",
    stroke_width: f32 = 0,
    shape: []const u8 = "rect",
    fit: []const u8 = "contain",
    font: Font = .{},
    headers: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    source: []const u8 = "",
    clip: bool = false,
    children: []const []const u8 = &.{},
    origin: ?Origin = null,
    style: []const u8 = "",
};

pub const Keyframe = struct {
    t_ms: i64,
    value: []const f32,
    ease: []const u8 = "linear",
};

pub const Track = struct {
    target: []const u8,
    channel: []const u8,
    keyframes: []const Keyframe,
};

pub const Cue = struct {
    url: []const u8,
    start_ms: i64 = 0,
    offset_ms: i64 = 0,
    volume: f32 = 1,
};

pub const Soundtrack = struct {
    url: []const u8,
    start_ms: i64 = 0,
    offset_ms: i64 = 0,
    volume: f32 = 1,
};

pub const Transition = struct {
    kind: []const u8 = "none",
    duration_ms: i64 = 0,
};

pub const SlideCanvas = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    background: []const u8 = "#0a0d14",
};

pub const Slide = struct {
    id: []const u8,
    start_ms: i64 = 0,
    duration_ms: i64 = 4000,
    transition: Transition = .{},
    canvas: SlideCanvas = .{},
    nodes: []Node = &.{},
    tracks: []Track = &.{},
    cues: []Cue = &.{},
};

pub const Deck = struct {
    version: u32 = version,
    slug: []const u8,
    title: []const u8,
    path: []const u8,
    fps: u32 = 30,
    size: Size = .{},
    soundtrack: ?Soundtrack = null,
    /// Frontmatter cover: a URL, markdown `![alt](url)`, or an HTML `<video>`.
    image: []const u8 = "",
    slides: []Slide = &.{},
};

pub const IndexEntry = struct {
    slug: []const u8,
    title: []const u8,
    path: []const u8,
    duration_ms: i64 = 0,
    size: Size = .{},
    image: []const u8 = "",
    sha256: []const u8 = "",
};

pub const Index = struct {
    version: u32 = version,
    generated_at: i64 = 0,
    documents: []const IndexEntry = &.{},
};

pub fn durationOf(deck: Deck) i64 {
    if (deck.slides.len == 0) return 0;
    const last = deck.slides[deck.slides.len - 1];
    return last.start_ms + last.duration_ms;
}

pub fn serializeDeck(allocator: zstd.mem.Allocator, deck: Deck) ![]u8 {
    return common.json.serializeOpts(allocator, deck, .{ .whitespace = .indent_2 });
}

pub fn serializeIndex(allocator: zstd.mem.Allocator, index: Index) ![]u8 {
    return common.json.serializeOpts(allocator, index, .{ .whitespace = .indent_2 });
}

pub fn deserializeDeck(allocator: zstd.mem.Allocator, bytes: []const u8) !Deck {
    return common.json.deserializeLeakyOpts(Deck, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn deserializeIndex(allocator: zstd.mem.Allocator, bytes: []const u8) !Index {
    return common.json.deserializeLeakyOpts(Index, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub const LoadedIndex = struct {
    arena: zstd.heap.ArenaAllocator,
    data: Index,
    by_slug: zstd.StringHashMap(usize),

    pub fn empty(allocator: zstd.mem.Allocator) LoadedIndex {
        return .{
            .arena = zstd.heap.ArenaAllocator.init(allocator),
            .data = .{},
            .by_slug = zstd.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *LoadedIndex) void {
        self.by_slug.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const LoadedIndex, slug: []const u8) ?*const IndexEntry {
        const index = self.by_slug.get(slug) orelse return null;
        return &self.data.documents[index];
    }

    pub fn load(allocator: zstd.mem.Allocator, dir: anytype, name: []const u8) !LoadedIndex {
        const bytes = dir.readFileAlloc(allocator, name, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return empty(allocator),
            else => return err,
        };
        defer allocator.free(bytes);
        return parseIndex(allocator, bytes);
    }

    pub fn parseIndex(allocator: zstd.mem.Allocator, bytes: []const u8) !LoadedIndex {
        var arena = zstd.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const data = try deserializeIndex(arena.allocator(), bytes);
        var by_slug = zstd.StringHashMap(usize).init(allocator);
        errdefer by_slug.deinit();
        for (data.documents, 0..) |doc, i| {
            try by_slug.put(doc.slug, i);
        }
        return .{ .arena = arena, .data = data, .by_slug = by_slug };
    }
};

pub fn compileTracks(
    allocator: zstd.mem.Allocator,
    tracks: []const Track,
) ![]animation.Track {
    var out: zstd.ArrayList(animation.Track) = .empty;
    errdefer out.deinit(allocator);
    for (tracks) |track| {
        const channel = animation.Channel.parse(track.channel) orelse continue;
        var keys: zstd.ArrayList(animation.Keyframe) = .empty;
        errdefer keys.deinit(allocator);
        for (track.keyframes) |kf| {
            try keys.append(allocator, .{
                .t_ms = kf.t_ms,
                .x = if (kf.value.len > 0) kf.value[0] else 0,
                .y = if (kf.value.len > 1) kf.value[1] else if (kf.value.len > 0) kf.value[0] else 0,
                .ease = animation.Ease.parse(kf.ease),
            });
        }
        try out.append(allocator, .{
            .target = track.target,
            .channel = channel,
            .keyframes = try keys.toOwnedSlice(allocator),
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeCompiledTracks(allocator: zstd.mem.Allocator, tracks: []animation.Track) void {
    for (tracks) |track| allocator.free(track.keyframes);
    allocator.free(tracks);
}

pub fn slideIndexAt(deck: Deck, t_ms: i64) usize {
    var timings: [64]carousel.Timing = undefined;
    const n = @min(deck.slides.len, timings.len);
    for (deck.slides[0..n], 0..) |slide, i| {
        timings[i] = .{ .start_ms = slide.start_ms, .duration_ms = slide.duration_ms };
    }
    return carousel.slideAt(timings[0..n], t_ms);
}

const testing = zstd.testing;

test "deck json round-trips" {
    const allocator = testing.allocator;
    var arena = zstd.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const values = try a.dupe(f32, &.{ 0, 40 });
    const keys = try a.dupe(Keyframe, &.{.{ .t_ms = 0, .value = values, .ease = "linear" }});
    const tracks = try a.dupe(Track, &.{.{ .target = "title", .channel = "translate", .keyframes = keys }});
    const nodes = try a.dupe(Node, &.{.{
        .id = "title",
        .kind = "text",
        .bounds = .{ .x = 80, .y = 80, .w = 1760, .h = 96 },
        .text = "Hello",
    }});
    const slides = try a.dupe(Slide, &.{.{
        .id = "open",
        .duration_ms = 4000,
        .nodes = nodes,
        .tracks = tracks,
    }});
    const deck = Deck{
        .slug = "demo",
        .title = "Demo",
        .path = "demo.md",
        .slides = slides,
    };
    const bytes = try serializeDeck(allocator, deck);
    defer allocator.free(bytes);

    var parse_arena = zstd.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const back = try deserializeDeck(parse_arena.allocator(), bytes);
    try testing.expectEqualStrings("demo", back.slug);
    try testing.expectEqual(@as(usize, 1), back.slides.len);
    try testing.expectEqualStrings("title", back.slides[0].nodes[0].id);
}
