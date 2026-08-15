const zstd = @import("std");
const fs = @import("../compat_fs.zig");

const Sha1 = zstd.crypto.hash.Sha1;
const Sha256 = zstd.crypto.hash.sha2.Sha256;

const default_upload_prefix = "https://api.cloudinary.com";
const default_delivery_host = "res.cloudinary.com";
const multipart_boundary = "----ScorpioBoundary7MA4YWxkTrZu0gW";
const max_file_bytes: usize = 256 * 1024 * 1024;

pub const Error = error{CloudinaryError};

pub const ResourceType = enum { image, video, raw, auto };

/// The delivery type segment of an asset URL (…/{resource_type}/{delivery_type}/…).
pub const DeliveryType = enum { upload, authenticated, private, fetch };

/// Hash used to sign requests. Cloudinary accounts default to SHA-1; SHA-256
/// can be enabled account-wide, in which case both sides must agree.
pub const SignatureAlgorithm = enum { sha1, sha256 };

/// Controls how the API endpoint and delivery URLs are built.
pub const ResourceUrlConfig = struct {
    /// Serve delivery URLs over https (true) or http (false).
    secure: bool = true,
    /// Custom secure delivery domain (CNAME / private distribution) used for
    /// https URLs, e.g. "assets.example.com". Overrides the default host.
    secure_distribution: ?[]const u8 = null,
    /// Use the per-cloud private CDN host ("{cloud}-res.cloudinary.com").
    private_cdn: bool = false,
    /// Override the API base ("https://api.cloudinary.com") for uploads.
    upload_prefix: ?[]const u8 = null,
    /// Shard delivery across a1–a5 subdomains (domain sharding).
    cdn_subdomain: bool = false,
};

/// Client-wide configuration passed to `initConfig`.
pub const Config = struct {
    signature_algorithm: SignatureAlgorithm = .sha1,
    url: ResourceUrlConfig = .{},
};

/// A signed request parameter (raw, un-encoded value).
const Param = struct { key: []const u8, value: []const u8 };

/// Fixed-capacity builder for the signable param set. Wraps a caller-owned
/// buffer and only records params whose value is present, so callers can list
/// optional fields declaratively instead of hand-tracking an index.
const ParamList = struct {
    buf: []Param,
    len: usize = 0,

    fn add(self: *ParamList, key: []const u8, value: []const u8) void {
        self.buf[self.len] = .{ .key = key, .value = value };
        self.len += 1;
    }

    fn addOpt(self: *ParamList, key: []const u8, value: ?[]const u8) void {
        if (value) |v| self.add(key, v);
    }

    fn addBool(self: *ParamList, key: []const u8, value: ?bool) void {
        if (value) |b| self.add(key, boolStr(b));
    }

    fn items(self: *const ParamList) []const Param {
        return self.buf[0..self.len];
    }
};

const FilePart = struct { filename: []const u8, bytes: []const u8 };

/// The resource returned by upload and rename. Parsed leniently; Cloudinary
/// returns many more fields than we model.
pub const Resource = struct {
    public_id: []const u8,
    secure_url: []const u8 = "",
    url: []const u8 = "",
    bytes: u64 = 0,
    format: ?[]const u8 = null,
    resource_type: []const u8 = "",
    version: u64 = 0,
    etag: ?[]const u8 = null,
};

/// destroy returns {"result": "ok"} or {"result": "not found"}.
pub const DestroyResult = struct { result: []const u8 };

pub const UploadOptions = struct {
    resource_type: ResourceType = .raw,
    public_id: ?[]const u8 = null,
    folder: ?[]const u8 = null,
    tags: ?[]const u8 = null,
    overwrite: ?bool = null,
    invalidate: ?bool = null,
};

pub const RenameOptions = struct {
    resource_type: ResourceType = .raw,
    overwrite: ?bool = null,
    invalidate: ?bool = null,
};

pub const Cloudinary = struct {
    allocator: zstd.mem.Allocator,
    cloud_name: []const u8,
    api_key: []const u8,
    api_secret: []const u8,
    config: Config,
    client: zstd.http.Client,

    pub fn init(
        allocator: zstd.mem.Allocator,
        io: zstd.Io,
        cloud_name: []const u8,
        api_key: []const u8,
        api_secret: []const u8,
    ) Cloudinary {
        return initConfig(
            allocator,
            io,
            cloud_name,
            api_key,
            api_secret,
            .{},
        );
    }

    pub fn initConfig(
        allocator: zstd.mem.Allocator,
        io: zstd.Io,
        cloud_name: []const u8,
        api_key: []const u8,
        api_secret: []const u8,
        config: Config,
    ) Cloudinary {
        return .{
            .allocator = allocator,
            .cloud_name = cloud_name,
            .api_key = api_key,
            .api_secret = api_secret,
            .config = config,
            .client = .{ .allocator = allocator, .io = io },
        };
    }

    pub fn deinit(self: *Cloudinary) void {
        self.client.deinit();
        self.* = undefined;
    }

    pub fn uploadBytes(
        self: *Cloudinary,
        bytes: []const u8,
        filename: []const u8,
        opts: UploadOptions,
    ) !zstd.json.Parsed(Resource) {
        var buf: [5]Param = undefined;
        var params: ParamList = .{ .buf = &buf };
        params.addOpt("public_id", opts.public_id);
        params.addOpt("folder", opts.folder);
        params.addOpt("tags", opts.tags);
        params.addBool("overwrite", opts.overwrite);
        params.addBool("invalidate", opts.invalidate);

        return self.request(
            Resource,
            "upload",
            opts.resource_type,
            params.items(),
            .{
                .filename = filename,
                .bytes = bytes,
            },
        );
    }

    pub fn uploadFile(
        self: *Cloudinary,
        path: []const u8,
        opts: UploadOptions,
    ) !zstd.json.Parsed(Resource) {
        const bytes = try fs.cwd().readFileAlloc(self.allocator, path, max_file_bytes);
        defer self.allocator.free(bytes);
        return self.uploadBytes(bytes, fs.path.basename(path), opts);
    }

    pub fn rename(
        self: *Cloudinary,
        from_public_id: []const u8,
        to_public_id: []const u8,
        opts: RenameOptions,
    ) !zstd.json.Parsed(Resource) {
        var buf: [4]Param = undefined;
        var params: ParamList = .{ .buf = &buf };
        params.add("from_public_id", from_public_id);
        params.add("to_public_id", to_public_id);
        params.addBool("overwrite", opts.overwrite);
        params.addBool("invalidate", opts.invalidate);

        return self.request(Resource, "rename", opts.resource_type, params.items(), null);
    }

    pub fn destroy(
        self: *Cloudinary,
        public_id: []const u8,
        resource_type: ResourceType,
        invalidate: bool,
    ) !zstd.json.Parsed(DestroyResult) {
        var buf: [2]Param = undefined;
        var params: ParamList = .{ .buf = &buf };
        params.add("public_id", public_id);
        if (invalidate) params.add("invalidate", "true");

        return self.request(DestroyResult, "destroy", resource_type, params.items(), null);
    }

    fn request(
        self: *Cloudinary,
        comptime T: type,
        action: []const u8,
        resource_type: ResourceType,
        signable: []const Param,
        file: ?FilePart,
    ) !zstd.json.Parsed(T) {
        var arena = zstd.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var params: zstd.ArrayList(Param) = try .initCapacity(a, signable.len + 1);
        try params.appendSlice(a, signable);
        // Signable params + timestamp (api_key and signature are NOT signed).
        const timestamp = try zstd.fmt.allocPrint(a, "{d}", .{zstd.Io.Timestamp.now(self.client.io, .real).toSeconds()});
        try params.append(a, .{ .key = "timestamp", .value = timestamp });

        const signature = try self.sign(a, params.items);

        var body: zstd.ArrayList(u8) = .empty;
        const content_type = if (file) |f|
            try buildMultipart(a, &body, params.items, self.api_key, signature, f)
        else
            try buildUrlEncoded(a, &body, params.items, self.api_key, signature);

        const prefix = self.config.url.upload_prefix orelse default_upload_prefix;
        const url = try zstd.fmt.allocPrint(a, "{s}/v1_1/{s}/{s}/{s}", .{
            prefix,
            self.cloud_name,
            @tagName(resource_type),
            action,
        });

        var response: zstd.Io.Writer.Allocating = .init(a);
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body.items,
            .headers = .{ .content_type = .{ .override = content_type } },
            .response_writer = &response.writer,
        });

        if (res.status.class() != .success) {
            zstd.log.err("cloudinary {s} failed ({d}): {s}", .{
                action,
                @intFromEnum(res.status),
                response.written(),
            });
            return Error.CloudinaryError;
        }

        return zstd.json.parseFromSlice(
            T,
            self.allocator,
            response.written(),
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        );
    }

    fn sign(self: *Cloudinary, a: zstd.mem.Allocator, params: []Param) ![]u8 {
        const to_sign = try joinSorted(a, params);
        var buf: zstd.ArrayList(u8) = .empty;
        try buf.appendSlice(a, to_sign);
        try buf.appendSlice(a, self.api_secret);

        return switch (self.config.signature_algorithm) {
            .sha1 => hexDigest(a, Sha1, buf.items),
            .sha256 => hexDigest(a, Sha256, buf.items),
        };
    }

    /// Build a delivery URL for an already-uploaded asset, honoring the URL
    /// configuration (scheme, custom/private host, and domain sharding).
    pub fn deliveryUrl(
        self: *const Cloudinary,
        a: zstd.mem.Allocator,
        public_id: []const u8,
        resource_type: ResourceType,
        delivery_type: DeliveryType,
    ) ![]u8 {
        const cfg = self.config.url;
        const scheme = if (cfg.secure) "https" else "http";

        var host: zstd.ArrayList(u8) = .empty;
        if (cfg.cdn_subdomain) {
            const shard = (zstd.hash.Crc32.hash(public_id) % 5) + 1;
            try host.print(a, "a{d}.", .{shard});
        }
        if (cfg.secure and cfg.secure_distribution != null) {
            try host.appendSlice(a, cfg.secure_distribution.?);
        } else if (cfg.private_cdn) {
            try host.print(a, "{s}-{s}", .{ self.cloud_name, default_delivery_host });
        } else {
            try host.appendSlice(a, default_delivery_host);
        }

        return zstd.fmt.allocPrint(a, "{s}://{s}/{s}/{s}/{s}/{s}", .{
            scheme,
            host.items,
            self.cloud_name,
            @tagName(resource_type),
            @tagName(delivery_type),
            public_id,
        });
    }
};

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

fn hexDigest(a: zstd.mem.Allocator, comptime Hash: type, data: []const u8) ![]u8 {
    var digest: [Hash.digest_length]u8 = undefined;
    Hash.hash(data, &digest, .{});
    return a.dupe(u8, &zstd.fmt.bytesToHex(digest, .lower));
}

fn lessByKey(_: void, x: Param, y: Param) bool {
    return zstd.mem.lessThan(u8, x.key, y.key);
}

fn joinSorted(a: zstd.mem.Allocator, params: []Param) ![]u8 {
    zstd.sort.pdq(Param, params, {}, lessByKey);

    var buf: zstd.ArrayList(u8) = .empty;
    for (params, 0..) |p, i| {
        if (i != 0) try buf.append(a, '&');
        try buf.appendSlice(a, p.key);
        try buf.append(a, '=');
        try buf.appendSlice(a, p.value);
    }
    return buf.toOwnedSlice(a);
}

fn percentEncode(a: zstd.mem.Allocator, value: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var buf: zstd.ArrayList(u8) = .empty;
    for (value) |c| {
        if (zstd.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try buf.append(a, c);
        } else {
            try buf.append(a, '%');
            try buf.append(a, hex[c >> 4]);
            try buf.append(a, hex[c & 0x0f]);
        }
    }
    return buf.toOwnedSlice(a);
}

fn buildUrlEncoded(
    a: zstd.mem.Allocator,
    body: *zstd.ArrayList(u8),
    params: []const Param,
    api_key: []const u8,
    signature: []const u8,
) ![]const u8 {
    const all = try withAuth(a, params, api_key, signature);
    for (all, 0..) |p, i| {
        if (i != 0) try body.append(a, '&');
        try body.appendSlice(a, p.key);
        try body.append(a, '=');
        const encoded = try percentEncode(a, p.value);
        try body.appendSlice(a, encoded);
    }
    return "application/x-www-form-urlencoded";
}

fn buildMultipart(
    a: zstd.mem.Allocator,
    body: *zstd.ArrayList(u8),
    params: []const Param,
    api_key: []const u8,
    signature: []const u8,
    file: FilePart,
) ![]const u8 {
    const all = try withAuth(a, params, api_key, signature);
    for (all) |p| {
        try body.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{
            multipart_boundary,
            p.key,
            p.value,
        });
    }
    try body.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{
        multipart_boundary,
        file.filename,
    });
    try body.appendSlice(a, file.bytes);
    try body.print(a, "\r\n--{s}--\r\n", .{multipart_boundary});

    return zstd.fmt.allocPrint(a, "multipart/form-data; boundary={s}", .{multipart_boundary});
}

fn withAuth(
    a: zstd.mem.Allocator,
    params: []const Param,
    api_key: []const u8,
    signature: []const u8,
) ![]Param {
    var all: zstd.ArrayList(Param) = try .initCapacity(a, params.len + 2);
    try all.appendSlice(a, params);
    try all.append(a, .{ .key = "api_key", .value = api_key });
    try all.append(a, .{ .key = "signature", .value = signature });
    return all.toOwnedSlice(a);
}

const testing = zstd.testing;

test "joinSorted orders keys and joins raw values" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var params = [_]Param{
        .{ .key = "timestamp", .value = "1315060510" },
        .{ .key = "public_id", .value = "sample" },
    };
    const joined = try joinSorted(a, &params);
    try testing.expectEqualStrings("public_id=sample&timestamp=1315060510", joined);
}

test "sign matches Cloudinary reference vector" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Documented example: params {public_id=sample, timestamp=1315060510},
    // api_secret "abcd" -> SHA1("public_id=sample&timestamp=1315060510abcd").
    var client = Cloudinary.init(
        testing.allocator,
        testing.io,
        "demo",
        "key",
        "abcd",
    );
    defer client.deinit();

    var params = [_]Param{
        .{ .key = "timestamp", .value = "1315060510" },
        .{ .key = "public_id", .value = "sample" },
    };
    const signature = try client.sign(a, &params);
    try testing.expectEqualStrings("c3470533147774275dd37996cc4d0e68fd03cd4f", signature);
}

test "sign supports SHA-256 signature algorithm" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // SHA256("public_id=sample&timestamp=1315060510abcd").
    var client = Cloudinary.initConfig(
        testing.allocator,
        testing.io,
        "demo",
        "key",
        "abcd",
        .{
            .signature_algorithm = .sha256,
        },
    );
    defer client.deinit();

    var params = [_]Param{
        .{ .key = "timestamp", .value = "1315060510" },
        .{ .key = "public_id", .value = "sample" },
    };
    const signature = try client.sign(a, &params);
    try testing.expectEqualStrings(
        "0d4fe14b2b4a3f68a97ccc5097c43908b623d24293c296826a9390c14d891509",
        signature,
    );
}

test "deliveryUrl honors url configuration" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var default_client = Cloudinary.init(
        testing.allocator,
        testing.io,
        "demo",
        "key",
        "secret",
    );
    defer default_client.deinit();
    try testing.expectEqualStrings(
        "https://res.cloudinary.com/demo/image/upload/sample",
        try default_client.deliveryUrl(a, "sample", .image, .upload),
    );

    // http + private CDN host.
    var private_client = Cloudinary.initConfig(
        testing.allocator,
        testing.io,
        "demo",
        "key",
        "secret",
        .{
            .url = .{ .secure = false, .private_cdn = true },
        },
    );
    defer private_client.deinit();
    try testing.expectEqualStrings(
        "http://demo-res.cloudinary.com/demo/raw/upload/docs/report.pdf",
        try private_client.deliveryUrl(a, "docs/report.pdf", .raw, .upload),
    );

    // Custom secure distribution overrides the host.
    var cname_client = Cloudinary.initConfig(
        testing.allocator,
        testing.io,
        "demo",
        "key",
        "secret",
        .{
            .url = .{ .secure_distribution = "assets.example.com" },
        },
    );
    defer cname_client.deinit();
    try testing.expectEqualStrings(
        "https://assets.example.com/demo/image/authenticated/sample",
        try cname_client.deliveryUrl(a, "sample", .image, .authenticated),
    );
}

test "percentEncode escapes reserved characters, keeps unreserved" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const encoded = try percentEncode(a, "blog/a=b c~d");
    try testing.expectEqualStrings("blog%2Fa%3Db%20c~d", encoded);
}

test "urlencoded body carries auth fields with encoded values" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var body: zstd.ArrayList(u8) = .empty;
    const params = [_]Param{
        .{ .key = "public_id", .value = "blog/post" },
        .{ .key = "timestamp", .value = "123" },
    };
    const ct = try buildUrlEncoded(a, &body, &params, "the_key", "the_sig");
    try testing.expectEqualStrings("application/x-www-form-urlencoded", ct);

    // Value is percent-encoded on the wire even though it was signed raw.
    try testing.expect(zstd.mem.indexOf(u8, body.items, "public_id=blog%2Fpost") != null);
    try testing.expect(zstd.mem.indexOf(u8, body.items, "api_key=the_key") != null);
    try testing.expect(zstd.mem.indexOf(u8, body.items, "signature=the_sig") != null);
}

test "multipart body frames fields and a file part" {
    var arena = zstd.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var body: zstd.ArrayList(u8) = .empty;
    const params = [_]Param{
        .{ .key = "timestamp", .value = "123" },
    };
    const ct = try buildMultipart(a, &body, &params, "the_key", "the_sig", .{
        .filename = "chunk_0000.bin",
        .bytes = "RAWDATA",
    });

    try testing.expect(zstd.mem.startsWith(u8, ct, "multipart/form-data; boundary="));
    try testing.expect(zstd.mem.indexOf(u8, body.items, "name=\"timestamp\"") != null);
    try testing.expect(zstd.mem.indexOf(u8, body.items, "name=\"api_key\"") != null);
    try testing.expect(zstd.mem.indexOf(u8, body.items, "name=\"file\"; filename=\"chunk_0000.bin\"") != null);
    try testing.expect(zstd.mem.indexOf(u8, body.items, "RAWDATA") != null);
    try testing.expect(zstd.mem.endsWith(u8, body.items, "--\r\n"));
}

// Live end-to-end smoke test. Skipped by default (requires process.Init env wiring).
test "live upload -> rename -> destroy" {
    const a = testing.allocator;

    const cloud_name = zstd.process.getEnvVarOwned(a, "CLOUDINARY_CLOUDNAME") catch return error.SkipZigTest;
    defer a.free(cloud_name);
    const api_key = zstd.process.getEnvVarOwned(a, "CLOUDINARY_API_KEY") catch return error.SkipZigTest;
    defer a.free(api_key);
    const api_secret = zstd.process.getEnvVarOwned(a, "CLOUDINARY_API_SECRET") catch return error.SkipZigTest;
    defer a.free(api_secret);

    var client = Cloudinary.init(a, cloud_name, api_key, api_secret);
    defer client.deinit();

    var uploaded = try client.uploadBytes("scorpio smoke test\n", "scorpio_smoke.md", .{
        .resource_type = .raw,
        .public_id = "scorpio_smoke",
        .overwrite = true,
    });
    defer uploaded.deinit();
    try testing.expectEqualStrings("scorpio_smoke", uploaded.value.public_id);

    var renamed = try client.rename("scorpio_smoke", "scorpio_smoke_renamed", .{
        .resource_type = .raw,
        .overwrite = true,
    });
    defer renamed.deinit();
    try testing.expectEqualStrings("scorpio_smoke_renamed", renamed.value.public_id);

    var destroyed = try client.destroy("scorpio_smoke_renamed", .raw, true);
    defer destroyed.deinit();
    try testing.expectEqualStrings("ok", destroyed.value.result);
}
