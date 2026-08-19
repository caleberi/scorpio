const zstd = @import("std");
const fs = @import("../../compat_fs.zig");
const build_info = @import("build_info");
const cloudinary = @import("../../uploader/cloudinary.zig");
const loader = @import("../documents/loader.zig");
const common = @import("common");
const unixTimestamp = common.utils.unixTimestamp;

const Directory = loader.Directory;
const Sha256 = zstd.crypto.hash.sha2.Sha256;

/// Project name, sourced from `build.zig.zon` via the `build_info` module. Used
/// as the lifecycle attribute namespace (`{project}="…"` / `data-{project}="…"`)
/// and the default `public_id` folder prefix, so renaming the project renames
/// these consistently.
pub const project_name = build_info.project_name;

/// The markdown / plain HTML lifecycle attribute name, e.g. `scorpio`.
const tag_attr = project_name;
/// The HTML data-attribute variant, e.g. `data-scorpio`.
const data_tag_attr = zstd.fmt.comptimePrint("data-{s}", .{project_name});

/// Upper bound on a single markdown document read into memory.
const max_document_bytes: usize = 64 * 1024 * 1024;
/// Upper bound on a single media asset read into memory (matches the
/// Cloudinary client's `max_file_bytes`).
const max_asset_bytes: usize = 256 * 1024 * 1024;

const doc_extensions = [_][]const u8{ ".md", ".markdown" };

pub const image_extensions = [_][]const u8{
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif",
};
pub const video_extensions = [_][]const u8{
    ".mp4", ".webm", ".mov", ".m4v", ".ogv",
};

/// The media family a wrapper handles. Kept for API parity; the resource type
/// carried by `Config` is what actually drives uploads.
pub const Kind = enum { image, video };

/// Per-link lifecycle directive, parsed from a `scorpio="…"` markdown attribute
/// or a `data-scorpio="…"` HTML attribute.
pub const Lifecycle = enum {
    /// Upload if new/changed, keep the original asset on disk (default).
    keep,
    /// Upload, then delete the original asset from disk.
    delete,
    /// Force a re-upload (overwrite) even when the content hash is unchanged.
    update,

    fn parse(value: []const u8) Lifecycle {
        if (zstd.ascii.eqlIgnoreCase(value, "delete")) return .delete;
        if (zstd.ascii.eqlIgnoreCase(value, "update")) return .update;
        return .keep;
    }
};

pub const Config = struct {
    /// Directory the markdown documents are read from.
    input_dir: []const u8,
    /// Directory the rewritten markdown (and linkage JSON) is written to. May
    /// equal `input_dir` to rewrite in place within a staging tree.
    output_dir: []const u8,
    /// Base directory that local asset paths are resolved against. Defaults to
    /// the realpath of `input_dir`. When chaining processors over a staging
    /// dir, point this at the original source tree so relative asset paths
    /// still resolve.
    asset_root: ?[]const u8 = null,

    linkage_name: []const u8 = "media-links.json",
    public_id_prefix: []const u8 = project_name,
    included_extensions: []const []const u8 = &image_extensions,
    resource_type: cloudinary.ResourceType = .image,

    /// Honor `scorpio="delete"` by removing the original asset file.
    allow_delete: bool = true,
    /// Destroy Cloudinary assets whose linkage entry is no longer referenced by
    /// any scanned document.
    prune_orphans: bool = false,
};

/// One uploaded asset, keyed by its path relative to `asset_root`.
pub const AssetEntry = struct {
    source_path: []const u8,
    public_id: []const u8,
    resource_type: []const u8,
    url: []const u8,
    sha256: []const u8,
    bytes: u64 = 0,
    version: u64 = 0,
    tag: []const u8 = "keep",
    uploaded_at: i64 = 0,
};

/// On-disk shape of the linkage JSON sidecar.
pub const LinkageData = struct {
    version: u32 = 1,
    generated_at: i64 = 0,
    assets: []const AssetEntry = &.{},
};

const max_linkage_bytes: usize = 64 * 1024 * 1024;

/// A single media reference discovered in a document. `[start, end)` is the
/// byte range to replace; the replacement text is `before ++ <url> ++ after`,
/// where `before`/`after` already have any `scorpio` tag stripped out.
const Ref = struct {
    start: usize,
    end: usize,
    url: []const u8,
    tag: Lifecycle,
    before: []const u8,
    after: []const u8,
};

pub const Processor = struct {
    allocator: zstd.mem.Allocator,
    config: Config,
    cloud: *cloudinary.Cloudinary,
    arena: zstd.heap.ArenaAllocator,

    assets: zstd.ArrayList(AssetEntry) = .empty,
    index: zstd.StringHashMap(usize),

    pub fn init(
        allocator: zstd.mem.Allocator,
        config: Config,
        cloud: *cloudinary.Cloudinary,
    ) Processor {
        return .{
            .allocator = allocator,
            .config = config,
            .cloud = cloud,
            .arena = zstd.heap.ArenaAllocator.init(allocator),
            .index = zstd.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Processor) void {
        self.assets.deinit(self.allocator);
        self.index.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Load the prior linkage, walk the input tree, rewrite every markdown
    /// document into the staging dir, optionally prune orphans, and persist the
    /// updated linkage.
    pub fn run(self: *Processor) !void {
        try self.loadLinkage();

        var dir = try Directory.load(self.allocator, self.config.input_dir);
        defer dir.deinit();

        const cwd = try fs.realpathAlloc(self.allocator, ".");
        defer self.allocator.free(cwd);

        const asset_base = if (self.config.asset_root) |root|
            fs.realpathAlloc(self.allocator, root) catch try fs.path.resolve(self.allocator, &.{ cwd, root })
        else
            try self.allocator.dupe(u8, dir.root_path);
        defer self.allocator.free(asset_base);

        var referenced = zstd.StringHashMap(void).init(self.allocator);
        defer referenced.deinit();

        for (dir.files) |file| {
            const rel = relativePath(dir.root_path, file.path) orelse continue;
            if (!matchesAny(file.path, &doc_extensions)) continue;
            if (isHidden(rel)) continue;
            try self.processFile(cwd, asset_base, file.path, rel, &referenced);
        }

        if (self.config.prune_orphans) try self.pruneOrphans(&referenced);

        try self.writeLinkage();
    }

    fn processFile(
        self: *Processor,
        cwd: []const u8,
        asset_base: []const u8,
        abs_md: []const u8,
        rel_md: []const u8,
        referenced: *zstd.StringHashMap(void),
    ) !void {
        const content = try fs.cwd().readFileAlloc(self.allocator, abs_md, max_document_bytes);
        defer self.allocator.free(content);

        var scan_arena = zstd.heap.ArenaAllocator.init(self.allocator);
        defer scan_arena.deinit();
        const refs = try scanRefs(scan_arena.allocator(), content);

        const md_dir = fs.path.dirname(abs_md) orelse cwd;
        const source_md_dir = sourceMarkdownDir(scan_arena.allocator(), asset_base, rel_md);

        var out: zstd.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        var cursor: usize = 0;

        for (refs) |ref| {
            if (!isLocal(ref.url)) continue;
            if (!self.matchesExtension(ref.url)) continue;

            const abs_asset = resolveAssetPath(
                scan_arena.allocator(),
                source_md_dir,
                md_dir,
                asset_base,
                cwd,
                ref.url,
            ) catch continue;

            const key = try assetKey(self.arena.allocator(), cwd, asset_base, abs_asset);

            const bytes = fs.cwd().readFileAlloc(self.allocator, abs_asset, max_asset_bytes) catch |err| switch (err) {
                error.FileNotFound => {
                    zstd.log.warn("media reference not found on disk: {s}", .{abs_asset});
                    continue;
                },
                else => return err,
            };
            defer self.allocator.free(bytes);

            const hex = try sha256Hex(self.arena.allocator(), bytes);
            const new_url = try self.decideAndUpload(key, fs.path.basename(abs_asset), bytes, hex, ref.tag);

            try referenced.put(key, {});

            if (ref.tag == .delete and self.config.allow_delete) {
                fs.cwd().deleteFile(abs_asset) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }

            try out.appendSlice(self.allocator, content[cursor..ref.start]);
            try out.appendSlice(self.allocator, ref.before);
            try out.appendSlice(self.allocator, new_url);
            try out.appendSlice(self.allocator, ref.after);
            cursor = ref.end;
        }
        try out.appendSlice(self.allocator, content[cursor..]);

        try self.writeStaged(rel_md, out.items);
    }

    /// Decide how a referenced asset is handled relative to the prior linkage
    /// and return the delivery URL to substitute into the document.
    fn decideAndUpload(
        self: *Processor,
        key: []const u8,
        filename: []const u8,
        bytes: []const u8,
        hex: []const u8,
        tag: Lifecycle,
    ) ![]const u8 {
        const strings = self.arena.allocator();

        if (self.index.get(key)) |idx| {
            const entry = &self.assets.items[idx];
            const changed = !zstd.mem.eql(u8, entry.sha256, hex);
            if (!changed and tag != .update) return entry.url;

            var res = try self.cloud.uploadBytes(bytes, filename, .{
                .resource_type = self.config.resource_type,
                .public_id = entry.public_id,
                .overwrite = true,
                .invalidate = true,
                .tags = @tagName(tag),
            });
            defer res.deinit();

            entry.url = try self.deliveryUrl(strings, res.value, entry.public_id);
            entry.sha256 = try strings.dupe(u8, hex);
            entry.bytes = res.value.bytes;
            entry.version = res.value.version;
            entry.tag = @tagName(tag);
            entry.uploaded_at = unixTimestamp();
            return entry.url;
        }

        const public_id = try self.derivePublicId(strings, key);
        var res = try self.cloud.uploadBytes(bytes, filename, .{
            .resource_type = self.config.resource_type,
            .public_id = public_id,
            .overwrite = true,
            .invalidate = true,
            .tags = @tagName(tag),
        });
        defer res.deinit();

        const entry = AssetEntry{
            .source_path = try strings.dupe(u8, key),
            .public_id = public_id,
            .resource_type = @tagName(self.config.resource_type),
            .url = try self.deliveryUrl(strings, res.value, public_id),
            .sha256 = try strings.dupe(u8, hex),
            .bytes = res.value.bytes,
            .version = res.value.version,
            .tag = @tagName(tag),
            .uploaded_at = unixTimestamp(),
        };
        try self.assets.append(self.allocator, entry);
        try self.index.put(entry.source_path, self.assets.items.len - 1);
        return entry.url;
    }

    /// Prefer the signed secure URL returned by Cloudinary; fall back to the
    /// plain URL, then to a synthesized delivery URL.
    fn deliveryUrl(
        self: *Processor,
        strings: zstd.mem.Allocator,
        res: cloudinary.Resource,
        public_id: []const u8,
    ) ![]const u8 {
        if (res.secure_url.len > 0) return strings.dupe(u8, res.secure_url);
        if (res.url.len > 0) return strings.dupe(u8, res.url);
        return self.cloud.deliveryUrl(strings, public_id, self.config.resource_type, .upload);
    }

    fn derivePublicId(self: *Processor, strings: zstd.mem.Allocator, key: []const u8) ![]const u8 {
        return zstd.fmt.allocPrint(strings, "{s}/{s}", .{
            self.config.public_id_prefix,
            stripExtension(key),
        });
    }

    fn pruneOrphans(self: *Processor, referenced: *zstd.StringHashMap(void)) !void {
        var survivors: zstd.ArrayList(AssetEntry) = .empty;
        errdefer survivors.deinit(self.allocator);

        for (self.assets.items) |entry| {
            if (referenced.contains(entry.source_path)) {
                try survivors.append(self.allocator, entry);
                continue;
            }
            var res = self.cloud.destroy(entry.public_id, parseResourceType(entry.resource_type), true) catch |err| {
                zstd.log.warn("failed to destroy orphan {s}: {s}", .{ entry.public_id, @errorName(err) });
                continue;
            };
            res.deinit();
        }

        self.assets.deinit(self.allocator);
        self.assets = survivors;

        self.index.clearRetainingCapacity();
        for (self.assets.items, 0..) |entry, i| {
            try self.index.put(entry.source_path, i);
        }
    }

    fn loadLinkage(self: *Processor) !void {
        const path = try fs.path.join(self.arena.allocator(), &.{ self.config.output_dir, self.config.linkage_name });
        const bytes = fs.cwd().readFileAlloc(self.allocator, path, max_linkage_bytes) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        const data = try zstd.json.parseFromSliceLeaky(LinkageData, self.arena.allocator(), bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        for (data.assets) |asset| {
            try self.assets.append(self.allocator, asset);
            try self.index.put(asset.source_path, self.assets.items.len - 1);
        }
    }

    fn writeLinkage(self: *Processor) !void {
        try fs.cwd().makePath(self.config.output_dir);
        var dir = try fs.cwd().openDir(self.config.output_dir, .{});
        defer dir.close();

        const data = LinkageData{
            .version = 1,
            .generated_at = unixTimestamp(),
            .assets = self.assets.items,
        };
        const bytes = try zstd.json.Stringify.valueAlloc(self.allocator, data, .{ .whitespace = .minified });
        defer self.allocator.free(bytes);

        var file = try dir.createFile(self.config.linkage_name, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }

    fn writeStaged(self: *Processor, rel_md: []const u8, bytes: []const u8) !void {
        const full = try fs.path.join(self.arena.allocator(), &.{ self.config.output_dir, rel_md });
        defer self.arena.allocator().free(full);
        if (fs.path.dirname(full)) |parent| try fs.cwd().makePath(parent);
        try fs.cwd().writeFile(.{ .sub_path = full, .data = bytes });
    }

    fn matchesExtension(self: *Processor, url: []const u8) bool {
        return matchesAny(url, self.config.included_extensions);
    }
};

/// Directory of the original markdown file under `asset_root`. Image then video
/// processors chain over a staging tree; `../` media paths must still resolve
/// against the source post, not `packed/staging/…`.
fn sourceMarkdownDir(allocator: zstd.mem.Allocator, asset_base: []const u8, rel_md: []const u8) []const u8 {
    const rel_dir = fs.path.dirname(rel_md) orelse return asset_base;
    return fs.path.resolve(allocator, &.{ asset_base, rel_dir }) catch return asset_base;
}

/// Resolve a local media URL against the source markdown directory first, then
/// the file being rewritten (staging), then `asset_root`, then the process cwd.
/// That last fallback is how repo-root paths like `blobs/cover.jpeg` work from
/// nested posts. Missing files still return the first candidate so the caller
/// can warn.
fn resolveAssetPath(
    allocator: zstd.mem.Allocator,
    source_md_dir: []const u8,
    md_dir: []const u8,
    asset_base: []const u8,
    cwd: []const u8,
    url: []const u8,
) ![]u8 {
    const bases = [_][]const u8{ source_md_dir, md_dir, asset_base, cwd };
    var fallback: ?[]u8 = null;
    errdefer if (fallback) |path| allocator.free(path);

    for (bases) |base| {
        if (base.len == 0) continue;
        const candidate = try fs.path.resolve(allocator, &.{ base, url });
        if (assetExists(candidate)) {
            if (fallback) |path| allocator.free(path);
            return candidate;
        }
        if (fallback == null) {
            fallback = candidate;
        } else {
            allocator.free(candidate);
        }
    }
    return fallback orelse error.FileNotFound;
}

fn assetExists(path: []const u8) bool {
    _ = fs.cwd().statFile(path) catch return false;
    return true;
}

/// Linkage key relative to `asset_base`, or to cwd when the file lives outside
/// the blog tree (e.g. `blobs/cover.jpeg`).
fn assetKey(
    allocator: zstd.mem.Allocator,
    cwd: []const u8,
    asset_base: []const u8,
    abs_asset: []const u8,
) ![]u8 {
    const from_base = try fs.path.relative(allocator, cwd, null, asset_base, abs_asset);
    if (!isOutsideRoot(from_base)) return from_base;
    allocator.free(from_base);
    return fs.path.relative(allocator, cwd, null, cwd, abs_asset);
}

fn isOutsideRoot(rel: []const u8) bool {
    return zstd.mem.eql(u8, rel, "..") or
        zstd.mem.startsWith(u8, rel, "../") or
        zstd.mem.startsWith(u8, rel, "..\\");
}

/// Extract every markdown image/link and `<img>/<video>/<source>` HTML tag as a
/// `Ref`. Locality and extension filtering happen in the caller so both
/// processors can share this routine.
fn scanRefs(a: zstd.mem.Allocator, content: []const u8) ![]Ref {
    var refs: zstd.ArrayList(Ref) = .empty;
    errdefer refs.deinit(a);

    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '<' and i + 1 < content.len and zstd.ascii.isAlphabetic(content[i + 1])) {
            if (try parseHtml(a, content, i)) |ref| {
                try refs.append(a, ref);
                i = ref.end;
                continue;
            }
        } else if (c == ']' and i + 1 < content.len and content[i + 1] == '(') {
            if (try parseMarkdown(a, content, i)) |ref| {
                try refs.append(a, ref);
                i = ref.end + 1;
                continue;
            }
        }
        i += 1;
    }

    return refs.toOwnedSlice(a);
}

/// Parse `](target)` starting at the `]` in `content[bracket..]`.
fn parseMarkdown(a: zstd.mem.Allocator, content: []const u8, bracket: usize) !?Ref {
    const open = bracket + 1; // '('
    const close = zstd.mem.indexOfScalarPos(u8, content, open + 1, ')') orelse return null;

    // Skip leading whitespace inside the parens.
    var url_start = open + 1;
    while (url_start < close and isSpace(content[url_start])) url_start += 1;

    var url_end = url_start;
    while (url_end < close and !isSpace(content[url_end])) url_end += 1;

    const url = content[url_start..url_end];
    if (url.len == 0) return null;

    const trailing = zstd.mem.trim(u8, content[url_end..close], " \t");
    const parsed = try extractMarkdownTag(a, trailing);

    const after = if (parsed.rest.len > 0)
        try zstd.mem.concat(a, u8, &.{ " ", parsed.rest })
    else
        "";

    return .{
        .start = url_start,
        .end = close,
        .url = url,
        .tag = parsed.tag,
        .before = "",
        .after = after,
    };
}

const MarkdownTag = struct { tag: Lifecycle, rest: []const u8 };

/// Locate and remove a `scorpio` attribute from a markdown link's trailing
/// attribute string, returning the parsed lifecycle and the remaining text.
fn extractMarkdownTag(a: zstd.mem.Allocator, trailing: []const u8) !MarkdownTag {
    const at = indexOfIgnoreCase(trailing, tag_attr) orelse
        return .{ .tag = .keep, .rest = trailing };

    var e = at + tag_attr.len;
    while (e < trailing.len and isSpace(trailing[e])) e += 1;

    var value: []const u8 = "";
    if (e < trailing.len and trailing[e] == '=') {
        e += 1;
        while (e < trailing.len and isSpace(trailing[e])) e += 1;
        if (e < trailing.len and (trailing[e] == '"' or trailing[e] == '\'')) {
            const quote = trailing[e];
            const vstart = e + 1;
            const vend = zstd.mem.indexOfScalarPos(u8, trailing, vstart, quote) orelse trailing.len;
            value = trailing[vstart..vend];
            e = if (vend < trailing.len) vend + 1 else vend;
        } else {
            const vstart = e;
            while (e < trailing.len and !isSpace(trailing[e])) e += 1;
            value = trailing[vstart..e];
        }
    }

    const left = zstd.mem.trim(u8, trailing[0..at], " \t");
    const right = zstd.mem.trim(u8, trailing[e..], " \t");
    const rest = if (left.len > 0 and right.len > 0)
        try zstd.mem.concat(a, u8, &.{ left, " ", right })
    else if (left.len > 0)
        left
    else
        right;

    return .{ .tag = Lifecycle.parse(value), .rest = rest };
}

const HtmlAttr = struct {
    name: []const u8,
    value: []const u8,
    has_value: bool,
};

/// Parse an `<img>/<video>/<source>` tag beginning at `content[lt]` (the `<`).
fn parseHtml(a: zstd.mem.Allocator, content: []const u8, lt: usize) !?Ref {
    var p = lt + 1;
    const name_start = p;
    while (p < content.len and (zstd.ascii.isAlphanumeric(content[p]) or content[p] == '-')) p += 1;
    const elem = content[name_start..p];
    if (!(zstd.ascii.eqlIgnoreCase(elem, "img") or
        zstd.ascii.eqlIgnoreCase(elem, "video") or
        zstd.ascii.eqlIgnoreCase(elem, "source"))) return null;

    var attrs: zstd.ArrayList(HtmlAttr) = .empty;
    defer attrs.deinit(a);

    var self_closing = false;
    var tag_end: usize = content.len;

    while (p < content.len) {
        while (p < content.len and isSpace(content[p])) p += 1;
        if (p >= content.len) return null;
        if (content[p] == '>') {
            tag_end = p;
            break;
        }
        if (content[p] == '/') {
            self_closing = true;
            p += 1;
            continue;
        }

        const an_start = p;
        while (p < content.len and content[p] != '=' and !isSpace(content[p]) and content[p] != '>' and content[p] != '/') p += 1;
        const attr_name = content[an_start..p];
        if (attr_name.len == 0) {
            p += 1;
            continue;
        }

        var attr_value: []const u8 = "";
        var has_value = false;
        var probe = p;
        while (probe < content.len and isSpace(content[probe])) probe += 1;
        if (probe < content.len and content[probe] == '=') {
            has_value = true;
            probe += 1;
            while (probe < content.len and isSpace(content[probe])) probe += 1;
            if (probe < content.len and (content[probe] == '"' or content[probe] == '\'')) {
                const quote = content[probe];
                const vstart = probe + 1;
                const vend = zstd.mem.indexOfScalarPos(u8, content, vstart, quote) orelse return null;
                attr_value = content[vstart..vend];
                p = vend + 1;
            } else {
                const vstart = probe;
                while (probe < content.len and !isSpace(content[probe]) and content[probe] != '>') probe += 1;
                attr_value = content[vstart..probe];
                p = probe;
            }
        }

        try attrs.append(a, .{ .name = attr_name, .value = attr_value, .has_value = has_value });
    }

    if (tag_end == content.len) return null;

    var url: ?[]const u8 = null;
    var tag: Lifecycle = .keep;
    for (attrs.items) |attr| {
        if (zstd.ascii.eqlIgnoreCase(attr.name, "src")) {
            url = attr.value;
        } else if (zstd.ascii.eqlIgnoreCase(attr.name, data_tag_attr) or zstd.ascii.eqlIgnoreCase(attr.name, tag_attr)) {
            tag = Lifecycle.parse(attr.value);
        }
    }
    const src = url orelse return null;

    var before: zstd.ArrayList(u8) = .empty;
    errdefer before.deinit(a);
    var after: zstd.ArrayList(u8) = .empty;
    errdefer after.deinit(a);

    try before.append(a, '<');
    try before.appendSlice(a, elem);

    var seen_src = false;
    for (attrs.items) |attr| {
        if (zstd.ascii.eqlIgnoreCase(attr.name, data_tag_attr) or zstd.ascii.eqlIgnoreCase(attr.name, tag_attr)) continue;
        if (zstd.ascii.eqlIgnoreCase(attr.name, "src")) {
            try before.appendSlice(a, " ");
            try before.appendSlice(a, attr.name);
            try before.appendSlice(a, "=\"");
            try after.append(a, '"');
            seen_src = true;
            continue;
        }
        const buf = if (seen_src) &after else &before;
        try buf.append(a, ' ');
        try buf.appendSlice(a, attr.name);
        if (attr.has_value) {
            try buf.appendSlice(a, "=\"");
            try buf.appendSlice(a, attr.value);
            try buf.append(a, '"');
        }
    }
    try after.appendSlice(a, if (self_closing) "/>" else ">");

    return .{
        .start = lt,
        .end = tag_end + 1,
        .url = src,
        .tag = tag,
        .before = try before.toOwnedSlice(a),
        .after = try after.toOwnedSlice(a),
    };
}

fn isLocal(url: []const u8) bool {
    if (url.len == 0) return false;
    const remote = [_][]const u8{ "http://", "https://", "//", "data:", "mailto:", "tel:", "#" };
    inline for (remote) |prefix| {
        if (startsWithIgnoreCase(url, prefix)) return false;
    }
    return true;
}

fn matchesAny(path: []const u8, extensions: []const []const u8) bool {
    const ext = fs.path.extension(path);
    for (extensions) |candidate| {
        if (zstd.ascii.eqlIgnoreCase(ext, candidate)) return true;
    }
    return false;
}

fn sha256Hex(a: zstd.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return a.dupe(u8, &zstd.fmt.bytesToHex(digest, .lower));
}

fn parseResourceType(name: []const u8) cloudinary.ResourceType {
    if (zstd.mem.eql(u8, name, "image")) return .image;
    if (zstd.mem.eql(u8, name, "video")) return .video;
    if (zstd.mem.eql(u8, name, "raw")) return .raw;
    return .auto;
}

fn stripExtension(path: []const u8) []const u8 {
    const ext = fs.path.extension(path);
    return path[0 .. path.len - ext.len];
}

fn relativePath(root: []const u8, abs_path: []const u8) ?[]const u8 {
    if (!zstd.mem.startsWith(u8, abs_path, root)) return null;
    if (abs_path.len <= root.len + 1) return null;
    return abs_path[root.len + 1 ..];
}

fn isHidden(rel_path: []const u8) bool {
    var it = zstd.mem.splitScalar(u8, rel_path, fs.path.sep);
    while (it.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return true;
    }
    return false;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return zstd.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = zstd.testing;

test "scanRefs finds markdown and html references" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\intro
        \\![alt](./assets/a.png)
        \\![remote](https://cdn.example.com/x.png align="center")
        \\<img src="pics/b.jpg" alt="b">
        \\<video src="clips/c.mp4" controls></video>
        \\[doc](./notes.txt)
    ;

    const refs = try scanRefs(a, content);
    try testing.expectEqual(@as(usize, 5), refs.len);
    try testing.expectEqualStrings("./assets/a.png", refs[0].url);
    try testing.expectEqualStrings("https://cdn.example.com/x.png", refs[1].url);
    try testing.expectEqualStrings("pics/b.jpg", refs[2].url);
    try testing.expectEqualStrings("clips/c.mp4", refs[3].url);
    try testing.expectEqualStrings("./notes.txt", refs[4].url);
}

test "scanRefs finds nested source tags without src on parent" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = "<video><source src=\"media/c.mov\" type=\"video/quicktime\"></video>";
    const refs = try scanRefs(a, content);
    try testing.expectEqual(@as(usize, 1), refs.len);
    try testing.expectEqualStrings("media/c.mov", refs[0].url);
}

test "scanRefs parses lifecycle tags and strips them" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content =
        \\![](./a.png scorpio="delete" align="center")
        \\<img src="b.png" data-scorpio="update" alt="b">
    ;

    const refs = try scanRefs(a, content);
    try testing.expectEqual(@as(usize, 2), refs.len);

    try testing.expectEqual(Lifecycle.delete, refs[0].tag);
    try testing.expectEqualStrings(" align=\"center\"", refs[0].after);

    try testing.expectEqual(Lifecycle.update, refs[1].tag);
    // The scorpio attribute is stripped; the rebuilt tag keeps alt and src.
    try testing.expectEqualStrings("<img src=\"", refs[1].before);
    try testing.expectEqualStrings("\" alt=\"b\">", refs[1].after);
}

test "isLocal distinguishes local paths from remote urls" {
    try testing.expect(isLocal("./assets/a.png"));
    try testing.expect(isLocal("assets/a.png"));
    try testing.expect(!isLocal("https://cdn.example.com/a.png"));
    try testing.expect(!isLocal("HTTP://cdn.example.com/a.png"));
    try testing.expect(!isLocal("//cdn.example.com/a.png"));
    try testing.expect(!isLocal("data:image/png;base64,AAAA"));
    try testing.expect(!isLocal(""));
}

test "matchesAny is case-insensitive on extension" {
    try testing.expect(matchesAny("a.PNG", &image_extensions));
    try testing.expect(matchesAny("dir/b.jpeg", &image_extensions));
    try testing.expect(!matchesAny("c.mp4", &image_extensions));
    try testing.expect(matchesAny("clip.MP4", &video_extensions));
    try testing.expect(!matchesAny("d.png", &video_extensions));
}

test "resolveAssetPath finds nested-post and repo-root blob images" {
    const allocator = testing.allocator;

    const cwd = fs.realpathAlloc(allocator, ".") catch return error.SkipZigTest;
    defer allocator.free(cwd);

    const blob = try fs.path.join(allocator, &.{ cwd, "blobs/replication-and-versioning.jpeg" });
    defer allocator.free(blob);
    if (!assetExists(blob)) return error.SkipZigTest;

    const md_dir = try fs.path.join(allocator, &.{ cwd, "pages/blog/hashnode" });
    defer allocator.free(md_dir);
    const asset_base = try fs.path.join(allocator, &.{ cwd, "pages" });
    defer allocator.free(asset_base);

    {
        const found = try resolveAssetPath(allocator, md_dir, md_dir, asset_base, cwd, "../../../blobs/replication-and-versioning.jpeg");
        defer allocator.free(found);
        try testing.expect(zstd.mem.endsWith(u8, found, "blobs/replication-and-versioning.jpeg"));
    }
    {
        const found = try resolveAssetPath(allocator, md_dir, md_dir, asset_base, cwd, "blobs/replication-and-versioning.jpeg");
        defer allocator.free(found);
        try testing.expect(zstd.mem.endsWith(u8, found, "blobs/replication-and-versioning.jpeg"));
    }
    {
        const staging_md_dir = try fs.path.join(allocator, &.{ cwd, "packed/staging/blog/hashnode" });
        defer allocator.free(staging_md_dir);
        const found = try resolveAssetPath(
            allocator,
            md_dir,
            staging_md_dir,
            asset_base,
            cwd,
            "../../../blobs/replication-and-versioning.jpeg",
        );
        defer allocator.free(found);
        try testing.expect(zstd.mem.endsWith(u8, found, "blobs/replication-and-versioning.jpeg"));
        try testing.expect(zstd.mem.indexOf(u8, found, "packed") == null);
    }

    const key = try assetKey(allocator, cwd, asset_base, blob);
    defer allocator.free(key);
    try testing.expectEqualStrings("blobs/replication-and-versioning.jpeg", key);
}

test "linkage json round-trips through disk" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const assets = [_]AssetEntry{
        .{
            .source_path = "blog/assets/diagram.png",
            .public_id = "scorpio/blog/assets/diagram",
            .resource_type = "image",
            .url = "https://res.cloudinary.com/demo/image/upload/v1/scorpio/blog/assets/diagram.png",
            .sha256 = "deadbeef",
            .bytes = 1234,
            .version = 42,
            .tag = "keep",
            .uploaded_at = 1_733_600_000,
        },
    };

    const bytes = try zstd.json.Stringify.valueAlloc(allocator, LinkageData{
        .version = 1,
        .generated_at = 1_733_600_000,
        .assets = &assets,
    }, .{ .whitespace = .minified });
    defer allocator.free(bytes);
    try tmp.dir.writeFile(.{ .sub_path = "media-links.json", .data = bytes });

    const read_back = try tmp.dir.readFileAlloc(allocator, "media-links.json", max_linkage_bytes);
    defer allocator.free(read_back);

    var parse_arena = zstd.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const data = try zstd.json.parseFromSliceLeaky(LinkageData, parse_arena.allocator(), read_back, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    try testing.expectEqual(@as(usize, 1), data.assets.len);
    try testing.expectEqualStrings("scorpio/blog/assets/diagram", data.assets[0].public_id);
    try testing.expectEqual(@as(u64, 42), data.assets[0].version);
}

test "live run uploads local image, rewrites markdown, prunes on removal" {
    const allocator = testing.allocator;

    const cloud_name = zstd.process.getEnvVarOwned(allocator, "CLOUDINARY_CLOUDNAME") catch return error.SkipZigTest;
    defer allocator.free(cloud_name);
    const api_key = zstd.process.getEnvVarOwned(allocator, "CLOUDINARY_API_KEY") catch return error.SkipZigTest;
    defer allocator.free(api_key);
    const api_secret = zstd.process.getEnvVarOwned(allocator, "CLOUDINARY_API_SECRET") catch return error.SkipZigTest;
    defer allocator.free(api_secret);

    var client = cloudinary.Cloudinary.init(allocator, cloud_name, api_key, api_secret);
    defer client.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/blog/assets");
    // A 1x1 transparent PNG.
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
        0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
        0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    try tmp.dir.writeFile(.{ .sub_path = "src/blog/assets/pixel.png", .data = &png });
    try tmp.dir.writeFile(.{ .sub_path = "src/blog/post.md", .data = "# Post\n\n![pixel](assets/pixel.png)\n" });

    const src = try tmp.dir.realpathAlloc(allocator, "src");
    defer allocator.free(src);
    const stage = try zstd.fs.path.join(allocator, &.{ src, "..", "stage" });
    defer allocator.free(stage);

    {
        var processor = Processor.init(allocator, .{
            .input_dir = src,
            .output_dir = stage,
            .linkage_name = "images-links.json",
            .included_extensions = &image_extensions,
            .resource_type = .image,
            .public_id_prefix = "scorpio_test",
            .prune_orphans = true,
        }, &client);
        defer processor.deinit();
        try processor.run();

        try testing.expectEqual(@as(usize, 1), processor.assets.items.len);

        const staged_path = try zstd.fs.path.join(allocator, &.{ stage, "blog/post.md" });
        defer allocator.free(staged_path);
        const staged = try zstd.fs.cwd().readFileAlloc(allocator, staged_path, max_document_bytes);
        defer allocator.free(staged);
        try testing.expect(zstd.mem.indexOf(u8, staged, "res.cloudinary.com") != null);
    }

    // Remove the reference; a pruning run should destroy the orphan.
    try tmp.dir.writeFile(.{ .sub_path = "src/blog/post.md", .data = "# Post\n\nno media now\n" });
    {
        var processor = Processor.init(allocator, .{
            .input_dir = src,
            .output_dir = stage,
            .linkage_name = "images-links.json",
            .included_extensions = &image_extensions,
            .resource_type = .image,
            .public_id_prefix = "scorpio_test",
            .prune_orphans = true,
        }, &client);
        defer processor.deinit();
        try processor.run();
        try testing.expectEqual(@as(usize, 0), processor.assets.items.len);
    }
}
