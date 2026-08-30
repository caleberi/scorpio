const zstd = @import("std");
const fs = @import("compat_fs.zig");
const engine = @import("validation/engine.zig");
const schema = @import("validation/schema.zig");
const env = @import("env/loader.zig");
const EnvironmentParser = env.EnvironmentParser;

pub fn Validator(comptime T: type) type {
    return struct {
        allocator: zstd.mem.Allocator,
        engine: engine.Engine,
        schema: ?schema.Schema(T) = null,

        pub fn init(allocator: zstd.mem.Allocator) !Validator(T) {
            const e = try engine.Engine.init(allocator);
            return .{
                .allocator = allocator,
                .engine = e,
            };
        }

        pub fn deinit(self: *Validator(T)) void {
            if (self.schema) |*compiled| compiled.deinit();
            self.engine.deinit();
        }

        pub fn registerCustomValidator(
            self: *Validator(T),
            name: []const u8,
            validator_fn: engine.ValidatorFn,
        ) !void {
            try self.engine.registerValidator(
                name,
                validator_fn,
            );
        }

        pub fn registerCustomMessage(
            self: *Validator(T),
            validator_name: []const u8,
            message: []const u8,
        ) !void {
            try self.engine.registerDefaultMessage(
                validator_name,
                message,
            );
        }

        pub fn validate(self: *Validator(T), container: T, source: ?[]const u8) !void {
            const container_info = @typeInfo(T);

            if (container_info == .pointer and container_info.pointer.size == .one) {
                return try self.validate(container.*, source);
            }

            if (container_info != .@"struct") {
                return error.InvalidContainer;
            }

            const has_embedded = @hasDecl(T, "doc") or @hasDecl(T, "documentation");
            if (!has_embedded and source == null) {
                return error.MissingDocumentation;
            }

            if (source) |src| {
                var compiled = try schema.Schema(T).compile(self.allocator, src);
                defer compiled.deinit();
                try runSchema(&compiled, &self.engine, self.allocator, container);
                return;
            }

            if (schema.docOf(T).len == 0) return;

            if (self.schema == null) {
                self.schema = try schema.Schema(T).compile(self.allocator, null);
            }
            try runSchema(&self.schema.?, &self.engine, self.allocator, container);
        }

        fn runSchema(
            compiled: *schema.Schema(T),
            eng: *engine.Engine,
            allocator: zstd.mem.Allocator,
            container: T,
        ) !void {
            const outcome = try compiled.validate(eng, container);
            defer outcome.deinit(allocator);
            if (outcome == .err) {
                zstd.debug.print("\nValidation failed for field '{s}': {s}\n", .{
                    outcome.err.path,
                    outcome.err.message,
                });
                return error.ValidationFailed;
            }
        }
    };
}

test "builtin validators available after init" {
    const allocator = zstd.testing.allocator;
    var validator = try Validator(i32).init(allocator);
    defer validator.deinit();

    const result = try validator.engine.validate("name", .{ .string = "JohnDoe" }, "alpha", &.{});
    try zstd.testing.expect(result.valid);
}

test "custom validator registration" {
    const allocator = zstd.testing.allocator;
    var validator = try Validator(i32).init(allocator);
    defer validator.deinit();

    const customValidator = struct {
        fn custom(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
            const s = ctx.value.asString() orelse {
                return engine.ValidationResult.failure("Must be a string");
            };
            if (zstd.mem.eql(u8, s, "custom_value")) {
                return engine.ValidationResult.success();
            }
            return engine.ValidationResult.failure("Must be 'custom_value'");
        }
    }.custom;

    try validator.registerCustomValidator("custom", customValidator);
    try validator.registerCustomMessage("custom", "Custom validation failed");

    var result = try validator.engine.validate("field", .{ .string = "custom_value" }, "custom", &.{});
    try zstd.testing.expect(result.valid);
    {
        result = try validator.engine.validate("field", .{ .string = "custom_value343" }, "custom", &.{});
        try zstd.testing.expect(!result.valid);
    }
}

test "complete engine validation" {
    const allocator = zstd.testing.allocator;

    const User = struct {
        const doc: []const u8 =
            \\// User type allows to store user
            \\// This struct represents a user account with validation
            \\// @validation
            \\// @property: name
            \\//   @validator: @alpha,@min_length=2,@max_length=56
            \\//   @messages:
            \\//     @alpha - "Must be alphabetic only"
            \\//     @min_length - "Name must be at least 24 characters"
            \\//     @max_length - "Name cannot exceed 56 characters"
            \\// @property: age
            \\//   @validator: @numeric,@min=10,@max=130
            \\//   @messages:
            \\//     @min - "Age must be at least 10"
            \\//     @max - "Age cannot exceed 130"
            \\// @property: email
            \\//   @validator: @email,@endswith=".com,.it,.edu"
            \\//   @messages:
            \\//     @email - "This should be a valid email"
            \\//     @endswith - "Email must end with .com, .it, or .edu"
        ;
        name: []const u8,
        age: i32,
        email: []const u8,
    };

    var validator = try Validator(User).init(allocator);
    defer validator.deinit();

    try validator.registerCustomValidator(
        "endswith",
        struct {
            fn endswith(context: engine.Context) engine.ValidationError!engine.ValidationResult {
                if (context.params.len != 1) {
                    return engine.ValidationError.InvalidParameterCount;
                }

                const field_str = context.value.asString() orelse {
                    return engine.ValidationResult.failure("Value must be a string");
                };

                const allowed = context.params[0].asString() orelse {
                    return engine.ValidationError.InvalidParameterType;
                };

                var suffixes = zstd.mem.splitSequence(u8, allowed, ",");
                while (suffixes.next()) |suffix| {
                    const trimmed_suffix = zstd.mem.trim(u8, suffix, " \t");
                    if (zstd.mem.endsWith(u8, field_str, trimmed_suffix)) {
                        return engine.ValidationResult.success();
                    }
                }

                var error_buf: [256]u8 = undefined;
                const error_msg = try zstd.fmt.bufPrint(
                    &error_buf,
                    "Value does not end with any of: {s}",
                    .{allowed},
                );
                return engine.ValidationResult.failure(error_msg);
            }
        }.endswith,
    );

    try validator.registerCustomMessage(
        "endwith",
        "Value should have some sort of specified ending suffix",
    );

    const user = User{
        .name = "Joe",
        .age = 25,
        .email = "john@example.com",
    };

    try validator.validate(user, null);
}

test "nested struct validation" {
    const allocator = zstd.testing.allocator;

    const Address = struct {
        pub const doc: []const u8 =
            \\// @validation
            \\// @property: street
            \\//   @validator: @required,@min_length=5
            \\//   @messages:
            \\//     required - "Street is required"
            \\//     min_length - "Street must be at least 5 characters"
            \\// @property: city
            \\//   @validator: @required,@alpha
            \\//   @messages:
            \\//     required - "City is required"
            \\//     alpha - "City must be alphabetic"
        ;
        street: []const u8,
        city: []const u8,
    };

    const User = struct {
        pub const doc: []const u8 =
            \\// @validation
            \\// @property: name
            \\//   @validator: @required,@alpha
            \\//   @messages:
            \\//     required - "Name is required"
            \\//     alpha - "Name must be alphabetic"
        ;
        name: []const u8,
        address: Address,
    };

    const user = User{
        .name = "John",
        .address = Address{
            .street = "Main Street",
            .city = "Boston",
        },
    };

    var validator = try Validator(User).init(allocator);
    defer validator.deinit();

    try validator.validate(user, null);
}

test "validation with external source" {
    const allocator = zstd.testing.allocator;
    const Product = struct {
        name: []const u8,
        price: i32,
    };

    var validator = try Validator(Product).init(allocator);
    defer validator.deinit();

    const validation_source =
        \\// @validation
        \\// @property: name
        \\//   @validator: @required,@min_length=3
        \\//   @messages:
        \\//     required - "Name is required"
        \\//     min_length - "Name must be at least 3 characters"
        \\// @property: price
        \\//   @validator: @required,@min=0
        \\//   @messages:
        \\//     required - "Price is required"
        \\//     min - "Price must be non-negative"
    ;

    const product = Product{
        .name = "Widget",
        .price = 100,
    };

    try validator.validate(product, validation_source);
}

test "complex environment configuration with validation" {
    const allocator = zstd.testing.allocator;

    const DatabaseConfig = struct {
        pub const doc: []const u8 =
            \\// Database configuration
            \\// @validation
            \\// @property: host
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "Database host is required"
            \\//     min_length - "Database host cannot be empty"
            \\// @property: port
            \\//   @validator: @required,@min=1024,@max=65535
            \\//   @messages:
            \\//     required - "Database port is required"
            \\//     min - "Port must be at least 1024"
            \\//     max - "Port cannot exceed 65535"
            \\// @property: name
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "Database name is required"
            \\//     min_length - "Database name cannot be empty"
            \\// @property: user
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "Database user is required"
            \\//     min_length - "Database user cannot be empty"
            \\// @property: password
            \\//   @validator: @required,@min_length=8
            \\//   @messages:
            \\//     required - "Database password is required"
            \\//     min_length - "Password must be at least 8 characters"
            \\// @property: url
            \\//   @validator: @required,@min_length=10
            \\//   @messages:
            \\//     required - "Database URL is required"
            \\//     min_length - "Database URL must be at least 10 characters"
            \\// @property: external_port
            \\//   @validator: @required,@min=1024,@max=65535
            \\//   @messages:
            \\//     required - "External port is required"
            \\//     min - "External port must be at least 1024"
            \\//     max - "External port cannot exceed 65535"
            \\// @property: external_host
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "External host is required"
            \\//     min_length - "External host cannot be empty"
        ;

        host: []const u8,
        port: i32,
        name: []const u8,
        user: []const u8,
        password: []const u8,
        url: []const u8,
        external_port: i32,
        external_host: []const u8,
    };

    const ApiConfig = struct {
        pub const doc: []const u8 =
            \\// API configuration
            \\// @validation
            \\// @property: prefix
            \\//   @validator: @required,@alpha,@min_length=1,@max_length=20
            \\//   @messages:
            \\//     required - "API prefix is required"
            \\//     alpha - "API prefix must be alphabetic"
            \\//     min_length - "API prefix cannot be empty"
            \\//     max_length - "API prefix cannot exceed 20 characters"
            \\// @property: version
            \\//   @validator: @required,@min_length=1,@max_length=10
            \\//   @messages:
            \\//     required - "API version is required"
            \\//     min_length - "API version cannot be empty"
            \\//     max_length - "API version cannot exceed 10 characters"
        ;

        prefix: []const u8,
        version: []const u8,
    };

    const FirebaseConfig = struct {
        pub const doc: []const u8 =
            \\// Firebase configuration
            \\// @validation
            \\// @property: app_name
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "Firebase app name is required"
            \\//     min_length - "Firebase app name cannot be empty"
        ;

        database_url: ?[]const u8 = null,
        project_id: ?[]const u8 = null,
        storage_bucket: ?[]const u8 = null,
        credential_path: ?[]const u8 = null,
        credential: ?[]const u8 = null,
        messaging_sender_id: ?[]const u8 = null,
        app_id: ?[]const u8 = null,
        measurement_id: ?[]const u8 = null,
        app_name: []const u8,
    };

    const SlackConfig = struct {
        bot_token: ?[]const u8 = null,
        api_url: ?[]const u8 = null,
        username: ?[]const u8 = null,
        icon_emoji: ?[]const u8 = null,
        icon_url: ?[]const u8 = null,
        default_channel: ?[]const u8 = null,
    };

    const EmailConfig = struct {
        sendgrid_api_key: ?[]const u8 = null,
        mail_default_from: ?[]const u8 = null,
        mail_sandbox_mode: ?[]const u8 = null,
    };

    const SmsConfig = struct {
        provider_name: ?[]const u8 = null,
        base_url: ?[]const u8 = null,
        token: ?[]const u8 = null,
    };

    const AppConfig = struct {
        pub const doc: []const u8 =
            \\// Application configuration
            \\// @validation
            \\// @property: node_env
            \\//   @validator: @required,@alpha,@min_length=1
            \\//   @messages:
            \\//     required - "Node environment is required"
            \\//     alpha - "Node environment must be alphabetic"
            \\//     min_length - "Node environment cannot be empty"
            \\// @property: port
            \\//   @validator: @required,@min=1024,@max=65535
            \\//   @messages:
            \\//     required - "Application port is required"
            \\//     min - "Port must be at least 1024"
            \\//     max - "Port cannot exceed 65535"
            \\// @property: log_level
            \\//   @validator: @required,@alpha,@min_length=1
            \\//   @messages:
            \\//     required - "Log level is required"
            \\//     alpha - "Log level must be alphabetic"
            \\//     min_length - "Log level cannot be empty"
            \\// @property: compose_project_name
            \\//   @validator: @required,@min_length=1
            \\//   @messages:
            \\//     required - "Compose project name is required"
            \\//     min_length - "Compose project name cannot be empty"
            \\// @property: redis_url
            \\//   @validator: @required,@url,@min_length=10
            \\//   @messages:
            \\//     required - "Redis URL is required"
            \\//     min_length - "Redis URL must be at least 10 characters"
        ;

        node_env: []const u8,
        port: i32,
        log_level: []const u8,
        compose_project_name: []const u8,
        redis_url: []const u8,

        email: *EmailConfig,

        db: *DatabaseConfig,
        api: *ApiConfig,

        firebase: *FirebaseConfig,
        slack: *SlackConfig,

        sms: *SmsConfig,
    };

    const env_content =
        \\NODE_ENV=development
        \\PORT=3000
        \\LOG_LEVEL=debug
        \\
        \\DB_HOST=postgres
        \\DB_PORT=5432
        \\DB_NAME=circle_market_dev
        \\DB_USER=circle_market_user
        \\DB_PASSWORD=circle_market_password
        \\DB_URL=postgresql://${DB_NAME}:circle_market_password@postgres:5432/circle_market_dev
        \\
        \\DB_EXTERNAL_PORT=5433
        \\DB_EXTERNAL_HOST=localhost
        \\
        \\API_PREFIX=api
        \\API_VERSION=v1
        \\
        \\COMPOSE_PROJECT_NAME=circle-market-backend
        \\
        \\REDIS_URL=redis://redis:6379
        \\
        \\FIREBASE_DATABASE_URL=https://circle-market-dev.firebaseio.com
        \\FIREBASE_PROJECT_ID=circle-market-dev
        \\FIREBASE_STORAGE_BUCKET=circle-market-dev.appspot.com
        \\FIREBASE_CREDENTIAL_PATH=/app/config/firebase-credentials.json
        \\FIREBASE_CREDENTIAL={"type":"service_account","project_id":"circle-market-dev"}
        \\FIREBASE_MESSAGING_SENDER_ID=123456789012
        \\FIREBASE_APP_ID=1:123456789012:web:abcdef123456
        \\FIREBASE_MEASUREMENT_ID=G-ABCDEFGHIJ
        \\FIREBASE_APP_NAME=[DEFAULT]
        \\
        \\SLACK_BOT_TOKEN=xxxxxxxxxx
        \\SLACK_API_URL=https://slack.com/api
        \\SLACK_USERNAME=CircleMarketBot
        \\SLACK_ICON_EMOJI=:robot_face:
        \\SLACK_ICON_URL=https://example.com/slack-icon.png
        \\SLACK_DEFAULT_CHANNEL=#general
        \\
        \\EMAIL_SENDGRID_API_KEY=SGabcdefghijklmnopqrstuvwx
        \\EMAIL_MAIL_DEFAULT_FROM=noreply@circlemarket.com
        \\EMAIL_MAIL_SANDBOX_MODE=true
        \\
        \\SMS_PROVIDER_NAME=twilio
        \\SMS_BASE_URL=https://api.twilio.com/2010-04-01
        \\SMS_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
    ;

    var tmp_dir = zstd.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = zstd.testing.io;

    try tmp_dir.dir.writeFile(io, .{
        .data = env_content,
        .sub_path = "complex.env",
    });
    defer tmp_dir.dir.deleteFile(io, "complex.env") catch {};

    const sub_path = try allocator.dupe(u8, &tmp_dir.sub_path);
    defer allocator.free(sub_path);

    const full_path = try zstd.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/complex.env",
        .{sub_path},
    );
    defer allocator.free(full_path);

    const abs_path = try fs.realpathAlloc(allocator, full_path);
    defer allocator.free(abs_path);

    var env_parser = try EnvironmentParser(AppConfig).init(
        allocator,
        .{
            .filepath = abs_path,
        },
    );

    const config = try env_parser.parse();
    defer env_parser.cleanup(config);

    try zstd.testing.expectEqualStrings("development", config.node_env);
    try zstd.testing.expectEqual(@as(i32, 3000), config.port);
    try zstd.testing.expectEqualStrings("debug", config.log_level);

    try zstd.testing.expectEqualStrings("postgres", config.db.host);
    try zstd.testing.expectEqual(@as(i32, 5432), config.db.port);
    try zstd.testing.expectEqualStrings("circle_market_dev", config.db.name);
    try zstd.testing.expectEqualStrings("circle_market_user", config.db.user);
    try zstd.testing.expectEqualStrings("circle_market_password", config.db.password);
    try zstd.testing.expectEqual(@as(i32, 5433), config.db.external_port);
    try zstd.testing.expectEqualStrings("localhost", config.db.external_host);

    try zstd.testing.expectEqualStrings("api", config.api.prefix);
    try zstd.testing.expectEqualStrings("v1", config.api.version);

    try zstd.testing.expectEqualStrings("circle-market-backend", config.compose_project_name);
    try zstd.testing.expectEqualStrings("redis://redis:6379", config.redis_url);

    try zstd.testing.expectEqualStrings("[DEFAULT]", config.firebase.app_name);
    try zstd.testing.expect(config.firebase.database_url != null);
    try zstd.testing.expect(config.firebase.project_id != null);

    try zstd.testing.expect(config.slack.bot_token != null);
    try zstd.testing.expect(config.email.sendgrid_api_key != null);
    try zstd.testing.expect(config.sms.provider_name != null);

    var vd = try Validator(AppConfig).init(allocator);
    defer vd.deinit();
    try vd.registerCustomValidator("url", struct {
        fn url_validator(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
            const s = ctx.value.asString() orelse {
                return engine.ValidationResult.failure("Failed to validate URL format");
            };
            const error_msg = "Failed to validate URL format";
            const schemes = [_][]const u8{ "https://", "http://", "ftp://", "postgres://", "redis://" };
            for (schemes) |scheme| {
                if (zstd.mem.startsWith(u8, s, scheme) and s.len > scheme.len and
                    zstd.mem.indexOfAny(u8, s, " \t\r\n") == null)
                {
                    return engine.ValidationResult.success();
                }
            }
            return engine.ValidationResult.failure(error_msg);
        }
    }.url_validator);
    try vd.registerCustomMessage("url", "The value must be a valid URL");
    try vd.validate(config.*, null);
}

test "environment configuration validation failure" {
    const allocator = zstd.testing.allocator;

    const Config = struct {
        pub const doc: []const u8 =
            \\// @validation
            \\// @property: port
            \\//   @validator: @required,@min=1024,@max=65535
            \\//   @messages:
            \\//     required - "Port is required"
            \\//     min - "Port must be at least 1024"
            \\//     max - "Port cannot exceed 65535"
        ;

        port: i32,
    };

    const env_content = "PORT=100";

    var tmp_dir = zstd.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const io = zstd.testing.io;

    try tmp_dir.dir.writeFile(io, .{
        .data = env_content,
        .sub_path = "invalid.env",
    });
    defer tmp_dir.dir.deleteFile(io, "invalid.env") catch {};

    const sub_path = try allocator.dupe(u8, &tmp_dir.sub_path);
    defer allocator.free(sub_path);

    const full_path = try zstd.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/invalid.env",
        .{sub_path},
    );
    defer allocator.free(full_path);

    const abs_path = try fs.realpathAlloc(allocator, full_path);
    defer allocator.free(abs_path);

    var env_parser = try EnvironmentParser(Config).init(
        allocator,
        .{
            .filepath = abs_path,
        },
    );

    const config = try env_parser.parse();
    defer env_parser.cleanup(config);

    var vd = try Validator(Config).init(allocator);
    defer vd.deinit();

    try zstd.testing.expectError(error.ValidationFailed, vd.validate(config.*, null));
}
