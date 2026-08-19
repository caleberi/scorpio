const zstd = @import("std");
const libraries = @import("libraries");
const common = @import("common");

const EnvironmentParser = libraries.dotenv.loader.EnvironmentParser;
const Validator = libraries.validator.Validator;
const engine = libraries.validation.engine;

pub const ServerConfig = struct {
    pub const doc: []const u8 =
        \\// @validation
        \\// @property: port
        \\//   @validator: @required,@min=1024,@max=65535
        \\//   @messages:
        \\//     required - "Application port is required"
        \\//     min - "Port must be at least 1024"
        \\//     max - "Port cannot exceed 65535"
        \\// @property: threads
        \\//   @validator: @required,@min=1,@max=100
        \\//   @messages:
        \\//     required - "Thread count is required"
        \\//     min - "Threads cannot be negative"
        \\//     max - "Threads cannot exceed 100"
        \\// @property: workers
        \\//   @validator: @required,@min=1,@max=100
        \\//   @messages:
        \\//     required - "Worker count is required"
        \\//     min - "Workers cannot be negative"
        \\//     max - "Workers cannot exceed 100"
    ;

    port: i32 = 9090,
    threads: i16 = 2,
    workers: i16 = 1,
};

pub const BlogConfig = struct {
    pub const doc: []const u8 =
        \\// @validation
        \\// @property: input_dir
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Blog input directory is required"
        \\//     min_length - "Blog input directory cannot be empty"
        \\// @property: pack_dir
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Blog pack directory is required"
        \\//     min_length - "Blog pack directory cannot be empty"
        \\// @property: staging_dir
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Blog staging directory is required"
        \\//     min_length - "Blog staging directory cannot be empty"
        \\// @property: prefetch_neighbors
        \\//   @validator: @required,@min=0,@max=10
        \\//   @messages:
        \\//     required - "Prefetch neighbor count is required"
        \\//     min - "Prefetch neighbors cannot be negative"
        \\//     max - "Prefetch neighbors cannot exceed 10"
    ;

    input_dir: []const u8 = "pages/blog",
    pack_dir: []const u8 = "packed/blog",
    staging_dir: []const u8 = "packed/staging",
    prefetch_neighbors: i32 = 1,
};

pub const CloudinaryConfig = struct {
    pub const doc: []const u8 =
        \\// @validation
        \\// @property: cloudname
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Cloudinary cloud name is required"
        \\//     min_length - "Cloudinary cloud name cannot be empty"
        \\// @property: api_key
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Cloudinary API key is required"
        \\//     min_length - "Cloudinary API key cannot be empty"
        \\// @property: api_secret
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Cloudinary API secret is required"
        \\//     min_length - "Cloudinary API secret cannot be empty"
        \\// @property: pack_prefix
        \\//   @validator: @required,@min_length=1
        \\//   @messages:
        \\//     required - "Cloudinary pack prefix is required"
        \\//     min_length - "Cloudinary pack prefix cannot be empty"
    ;

    cloudname: []const u8,
    api_key: []const u8,
    api_secret: []const u8,
    pack_prefix: []const u8 = "scorpio/blog/packed",
};

pub const DatabaseConfig = struct {
    pub const doc: []const u8 =
        \\// @validation
        \\// @property: url
        \\//   @validator: @required,@url,@min_length=10
        \\//   @messages:
        \\//     required - "Database URL is required"
        \\//     url - "Database URL must be a valid postgres URL"
        \\//     min_length - "Database URL must be at least 10 characters"
    ;

    url: []const u8,
};

pub const AppConfig = struct {
    pub const doc: []const u8 =
        \\// @validation
        \\// @property: log_level
        \\//   @validator: @required,@alpha,@min_length=1
        \\//   @messages:
        \\//     required - "Log level is required"
        \\//     alpha - "Log level must be alphabetic"
        \\//     min_length - "Log level cannot be empty"
    ;

    log_level: []const u8 = "info",
    server: *ServerConfig,
    blog: *BlogConfig,
    cloudinary: *CloudinaryConfig,
    db: *DatabaseConfig,
};

pub const Loaded = struct {
    parser: EnvironmentParser(AppConfig),
    config: *AppConfig,

    pub fn deinit(self: *Loaded) void {
        self.parser.cleanup(self.config);
        self.* = undefined;
    }
};

fn urlValidator(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
    const candidate = ctx.value.asString() orelse {
        return engine.ValidationResult.failure("Failed to validate URL format");
    };

    const UrlPrefixProbe = struct {
        candidate: []const u8,

        fn matchesPrefix(self: @This(), prefix: []const u8) bool {
            return zstd.mem.startsWith(u8, self.candidate, prefix);
        }
    };

    const allowed_schemes = [_][]const u8{
        "postgres://",
        "postgresql://",
        "http://",
        "https://",
    };

    const matching_schemes = common.utils.filter(
        []const u8,
        ctx.allocator,
        &allowed_schemes,
        UrlPrefixProbe{ .candidate = candidate },
        UrlPrefixProbe.matchesPrefix,
    ) catch {
        return engine.ValidationResult.failure("Failed to validate URL format");
    };
    defer ctx.allocator.free(matching_schemes);

    if (matching_schemes.len > 0) {
        return engine.ValidationResult.success();
    }
    return engine.ValidationResult.failure("Failed to validate URL format");
}

pub fn load(allocator: zstd.mem.Allocator, filepath: []const u8) !Loaded {
    var parser = try EnvironmentParser(AppConfig).init(
        allocator,
        .{
            .filepath = filepath,
        },
    );
    const config = try parser.parse();
    errdefer parser.cleanup(config);

    var vd = try Validator(AppConfig).init(allocator);
    defer vd.deinit();
    try vd.registerValidators();
    try vd.registerMessages();
    try vd.registerCustomValidator("url", urlValidator);
    try vd.validate(config.*, null);

    return .{
        .parser = parser,
        .config = config,
    };
}
