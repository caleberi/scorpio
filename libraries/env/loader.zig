const zstd = @import("std");
const fs = @import("../compat_fs.zig");
const bind = @import("./bind.zig");

pub const EnvironmentError = error{
    InvalidTag,
    MemoryError,
    LoaderIssue,
    InvalidContainer,
    MissingRequiredField,
    TypeConversionError,
    FieldNotFound,
    FailedResolution,
};

pub const Loader = *const fn (zstd.mem.Allocator, []const u8) anyerror!zstd.process.Environ.Map;

fn load_environment_variables(allocator: zstd.mem.Allocator, filepath: []const u8) !zstd.process.Environ.Map {
    if (filepath.len == 0) return error.InvalidPath;

    const dirname = fs.path.dirname(filepath);
    const basename = fs.path.basename(filepath);
    if (basename.len == 0) return error.InvalidPath;

    // Zig treats names like `.env` as having an empty extension; still allow them.
    const ext = fs.path.extension(basename);
    if (ext.len == 0 and basename[0] != '.') return error.InvalidPath;

    // Start from an empty map and overlay the .env file. OS env can be merged
    // by callers via a custom loader if needed.
    var env = zstd.process.Environ.Map.init(allocator);
    errdefer env.deinit();

    var dir = try fs.cwd().openDir(dirname orelse ".", .{ .access_sub_paths = false });
    defer dir.close();

    const file_stat = try dir.statFile(basename);
    const content = try dir.readFileAlloc(allocator, basename, file_stat.size);
    defer allocator.free(content);

    var iterator = zstd.mem.tokenizeSequence(u8, content, "\n");
    while (iterator.next()) |line| {
        const trimmed_line = zstd.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or trimmed_line[0] == '#') continue;

        var parts = zstd.mem.splitScalar(u8, trimmed_line, '=');
        const key_raw = parts.next() orelse continue;
        const value_raw = parts.rest();

        const key = zstd.mem.trim(u8, key_raw, " \t");
        const value = zstd.mem.trim(u8, value_raw, " \t");

        if (key.len == 0) continue;

        const resolved_value = try resolve_variables(
            allocator,
            value,
            env,
        );
        defer allocator.free(resolved_value);
        try env.put(key, resolved_value);
    }

    return env;
}

fn resolve_variables(
    allocator: zstd.mem.Allocator,
    value: []const u8,
    environment: zstd.process.Environ.Map,
) ![]u8 {
    var result = try zstd.ArrayList(u8).initCapacity(allocator, value.len);
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < value.len) {
        const start = zstd.mem.indexOfPos(u8, value, pos, "${") orelse {
            try result.appendSlice(allocator, value[pos..]);
            break;
        };
        try result.appendSlice(allocator, value[pos..start]);

        const name_start = start + 2;
        const name_end = zstd.mem.indexOfScalarPos(u8, value, name_start, '}') orelse {
            try result.appendSlice(allocator, value[start..]);
            break;
        };
        if (name_end == name_start) {
            try result.appendSlice(allocator, "${}");
            pos = name_end + 1;
            continue;
        }

        const var_name = value[name_start..name_end];
        var uppercase_var = try allocator.alloc(u8, var_name.len);
        defer allocator.free(uppercase_var);
        for (var_name, 0..) |ch, i| {
            uppercase_var[i] = zstd.ascii.toUpper(ch);
        }

        if (environment.get(uppercase_var)) |env_value| {
            try result.appendSlice(allocator, env_value);
        } else {
            try result.appendSlice(allocator, value[start .. name_end + 1]);
        }
        pos = name_end + 1;
    }

    return try result.toOwnedSlice(allocator);
}

pub fn EnvironmentParser(comptime T: type) type {
    return struct {
        allocator: zstd.mem.Allocator,
        loader: Loader,
        config: ParserConfig,

        pub const ParserConfig = struct {
            prefix: ?[]const u8 = null,
            filepath: []const u8,
            loader: ?Loader = null,
        };

        const Self = @This();

        pub fn init(allocator: zstd.mem.Allocator, config: ParserConfig) !Self {
            var ctx_loader: Loader = undefined;

            if (config.loader) |loader| {
                ctx_loader = loader;
            } else {
                ctx_loader = load_environment_variables;
            }

            return .{
                .allocator = allocator,
                .loader = ctx_loader,
                .config = config,
            };
        }

        pub fn parse(self: *Self) !*T {
            var env = try self.loader(self.allocator, self.config.filepath);
            defer env.deinit();

            return try bind.parse(T, self.allocator, self.config.prefix, env);
        }

        pub fn cleanup(self: *Self, container: *T) void {
            bind.deinit(T, self.allocator, container);
        }
    };
}

test EnvironmentParser {
    const io = zstd.testing.io;
    const Test = struct {
        name: []const u8,
        sub_path: []const u8,
        content: []const u8,
        prefix: ?[]const u8 = null,
        run_test: *const fn (
            allocator: zstd.mem.Allocator,
            filepath: []const u8,
            prefix: ?[]const u8,
        ) anyerror!void,
    };

    const generate_environment_file = struct {
        fn call(
            allocator: zstd.mem.Allocator,
            tmp_dir: *zstd.testing.TmpDir,
            sub_path: []const u8,
            content: []const u8,
        ) ![]u8 {
            try tmp_dir.dir.writeFile(io, .{
                .data = content,
                .sub_path = sub_path,
            });

            const cache_sub = try allocator.dupe(u8, @as([]const u8, &tmp_dir.sub_path));
            defer allocator.free(cache_sub);

            const full_path = try zstd.fmt.allocPrint(
                allocator,
                ".zig-cache/tmp/{s}/{s}",
                .{ cache_sub, sub_path },
            );
            defer allocator.free(full_path);

            return try fs.realpathAlloc(allocator, full_path);
        }
    }.call;

    const build_parser = struct {
        fn call(
            comptime T: type,
            allocator: zstd.mem.Allocator,
            filepath: []const u8,
            prefix: ?[]const u8,
        ) !EnvironmentParser(T) {
            return try EnvironmentParser(T).init(allocator, .{
                .filepath = filepath,
                .prefix = prefix,
            });
        }
    }.call;

    const testcases: []const Test = &.{
        .{
            .name = "basic types",
            .sub_path = "test.env",
            .content =
            \\PORT=100
            \\HOST=localhost
            \\DEBUG=true
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Config = struct {
                        port: i32 = 8080,
                        host: []const u8,
                        debug: bool = false,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    const config = try parser.parse();
                    defer parser.cleanup(config);
                    try zstd.testing.expectEqual(@as(i32, 100), config.port);
                    try zstd.testing.expectEqualStrings("localhost", config.host);
                    try zstd.testing.expect(config.debug);
                }
            }.executor,
        },
        .{
            .name = "with prefix",
            .sub_path = "db.env",
            .content =
            \\DB_URL=postgres://localhost/mydb
            \\DB_TIMEOUT=60
            ,
            .prefix = "DB",
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const DatabaseConfig = struct {
                        url: []const u8,
                        timeout: i32 = 30,
                    };
                    var parser = try build_parser(DatabaseConfig, allocator, filepath, prefix);
                    const config = try parser.parse();
                    defer parser.cleanup(config);
                    try zstd.testing.expectEqualStrings("postgres://localhost/mydb", config.url);
                    try zstd.testing.expectEqual(@as(i32, 60), config.timeout);
                }
            }.executor,
        },
        .{
            .name = "optional fields",
            .sub_path = "opt.env",
            .content =
            \\REQUIRED=value
            \\NUMBER=42
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Config = struct {
                        required: []const u8,
                        optional: ?[]const u8 = null,
                        number: ?i32 = null,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    const config = try parser.parse();
                    defer parser.cleanup(config);
                    try zstd.testing.expectEqualStrings("value", config.required);
                    try zstd.testing.expect(config.optional == null);
                    try zstd.testing.expectEqual(@as(?i32, 42), config.number);
                }
            }.executor,
        },
        .{
            .name = "missing required field",
            .sub_path = "missing.env",
            .content =
            \\PORT=3000
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Config = struct {
                        host: []const u8,
                        port: i32 = 8080,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    try zstd.testing.expectError(EnvironmentError.MissingRequiredField, parser.parse());
                }
            }.executor,
        },
        .{
            .name = "no leak on partial parse failure",
            .sub_path = "partial.env",
            .content =
            \\HOST=localhost
            \\PORT=not_a_number
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Config = struct {
                        host: []const u8,
                        port: i32,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    // host is allocated first; port convert fails — must not leak host
                    try zstd.testing.expectError(EnvironmentError.TypeConversionError, parser.parse());
                }
            }.executor,
        },
        .{
            .name = "no leak on nested partial parse failure",
            .sub_path = "nested_partial.env",
            .content =
            \\HOST=localhost
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Nested = struct {
                        name: []const u8,
                    };
                    const Config = struct {
                        host: []const u8,
                        nested: *Nested,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    // host allocated, then nested.name missing — must free host via errdefer
                    try zstd.testing.expectError(EnvironmentError.MissingRequiredField, parser.parse());
                }
            }.executor,
        },
        .{
            .name = "empty string default does not leak",
            .sub_path = "empty_default.env",
            .content =
            \\PORT=3000
            ,
            .run_test = struct {
                fn executor(
                    allocator: zstd.mem.Allocator,
                    filepath: []const u8,
                    prefix: ?[]const u8,
                ) anyerror!void {
                    const Config = struct {
                        host: []const u8 = "",
                        label: ?[]const u8 = "",
                        port: i32 = 8080,
                    };
                    var parser = try build_parser(Config, allocator, filepath, prefix);
                    const config = try parser.parse();
                    defer parser.cleanup(config);
                    try zstd.testing.expectEqualStrings("", config.host);
                    try zstd.testing.expect(config.label != null);
                    try zstd.testing.expectEqualStrings("", config.label.?);
                    try zstd.testing.expectEqual(@as(i32, 3000), config.port);
                }
            }.executor,
        },
    };

    const allocator = zstd.testing.allocator;

    for (testcases) |testcase| {
        var tmp_dir = zstd.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const abs_path = try generate_environment_file(
            allocator,
            &tmp_dir,
            testcase.sub_path,
            testcase.content,
        );
        defer allocator.free(abs_path);
        defer tmp_dir.dir.deleteFile(io, testcase.sub_path) catch {};

        try testcase.run_test(allocator, abs_path, testcase.prefix);
    }
}
