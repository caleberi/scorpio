// ============================================================================
// Design Overview: Compile-Time Type-Safe Validation Orchestrator
// ============================================================================
//
// This module implements the high-level validation orchestration layer that
// ties together lexing, parsing, and validation execution to provide a
// seamless, type-safe validation experience for Zig structs.
//
// Key Design Decisions:
// ---------------------
// 1. **Compile-Time Type Specialization**: Uses comptime generics to create
//    specialized validators for each struct type, enabling type-safe field
//    access and compile-time verification.
//
// 2. **Documentation-Driven Validation**: Extracts validation rules from
//    struct documentation (doc/documentation fields), keeping validation
//    metadata close to type definitions without runtime overhead.
//
// 3. **Full Pipeline Integration**: Orchestrates the complete validation flow:
//    Documentation → Lexing → Parsing → Validation → Error Reporting
//
// 4. **Nested Struct Support**: Recursively validates nested structs by
//    detecting struct fields with their own documentation and creating
//    sub-validators with inherited validator registrations.
//
// 5. **Flexible Documentation Sources**: Supports both embedded documentation
//    (struct decl fields) and external validation specifications passed at
//    runtime, enabling different validation contexts.
//
// 6. **Automatic Type Conversion**: Converts struct field values to strings
//    for validation, handling ints, floats, bools, and string slices with
//    appropriate formatting.
//
// Architecture Flow:
// ------------------
// 1. Create Validator(T) instance for struct type T
// 2. Register built-in and/or custom validators
// 3. Call validate(struct_instance, optional_source)
// 4. Validator extracts documentation (from struct or parameter)
// 5. Lexer tokenizes validation syntax
// 6. Parser generates validation specifications
// 7. For each field:
//    - Convert field value to string
//    - Look up validation spec by field name
//    - Execute validators with parameters
//    - Apply custom error messages
//    - Report failures or continue
// 8. Recursively validate nested structs
//
// Documentation Format:
// ---------------------
// Structs define validation rules in a `doc` or `documentation` field:
// ```zig
// const User = struct {
//     const doc =
//         \\// @validation
//         \\// @property: name
//         \\//   @validator: @alpha,@min_length=3
//         \\//   @messages:
//         \\//     alpha - "Name must be alphabetic"
//     ;
//     name: []const u8,
// };
// ```
//
// Nested Validation:
// ------------------
// When a struct field is itself a struct with documentation, the validator:
// 1. Detects the nested struct type
// 2. Creates a new sub-validator with a temporary allocator
// 3. Copies parent validator registrations to child
// 4. Recursively validates the nested instance
// 5. Cleans up the sub-validator
//
// This enables deep validation of complex object graphs while maintaining
// isolation between validation contexts.
//
// Memory Management:
// ------------------
// - Validator owns the validation engine
// - Creates temporary copies of field values for validation
// - Clones validator/message registries for nested validation
// - Uses defer blocks extensively to prevent leaks
// - Nested validators use isolated allocators (GeneralPurposeAllocator)
//
// Extension Points:
// -----------------
// - registerCustomValidator(): Add domain-specific validators
// - registerCustomMessage(): Override default error messages
// - External documentation: Provide validation specs separate from type
//
// Error Handling:
// ---------------
// - Returns errors for missing documentation, invalid containers
// - Prints validation failures with field name and custom message
// - Returns ValidationFailed error on first validation failure
//
// Performance Characteristics:
// ----------------------------
// - Documentation parsing: O(n) where n is doc length
// - Field validation: O(f * v) where f=fields, v=validators per field
// - Nested validation: Recursive with depth proportional to nesting level
// - Type conversion overhead: Minimal buffered formatting
//
// Usage Pattern:
// --------------
// ```zig
// var validator = try Validator(User).init(allocator);
// defer validator.deinit();
// try validator.registerValidators();
// try validator.registerMessages();
// try validator.validate(user_instance, null);
// ```
//
// ============================================================================

const zstd = @import("std");
const fs = @import("compat_fs.zig");
const lexer = @import("validation/lexer.zig");
const parser = @import("validation/parser.zig");
const engine = @import("validation/engine.zig");
const defaults = @import("validation/default.zig");
const EnvironmentParser = @import("env/loader.zig").EnvironmentParser;
const clib = @cImport({
    @cInclude("regex.h");
});

/// Creates a type-specialized validator for struct type T.
///
/// This is a type factory function that returns a validator instance
/// capable of validating values of type T using documentation-defined rules.
///
/// The validator integrates lexer, parser, and validation engine to provide
/// a complete validation pipeline from documentation to execution.
///
/// Type Parameter:
/// - T: The struct type to validate (must have validation documentation)
pub fn Validator(comptime T: type) type {
    return struct {
        /// Allocator for validator operations
        allocator: zstd.mem.Allocator,
        /// Validation engine instance (manages validators and execution)
        engine: engine.Engine,

        /// Initializes a new validator for type T.
        ///
        /// Creates an empty validation engine. Call registerValidators()
        /// and registerMessages() to populate with built-in validators.
        pub fn init(allocator: zstd.mem.Allocator) !Validator(T) {
            const e = try engine.Engine.init(allocator);
            return .{
                .allocator = allocator,
                .engine = e,
            };
        }

        /// Cleans up validator resources.
        ///
        /// Frees the underlying validation engine and all registered
        /// validator names and messages.
        pub fn deinit(self: *Validator(T)) void {
            self.engine.deinit();
        }

        /// Registers all built-in validators with the engine.
        ///
        /// Adds standard validators:
        /// - alpha: Alphabetic characters only
        /// - numeric: Integer validation
        /// - min_length/max_length: String length constraints
        /// - min/max: Numeric range constraints
        /// - required: Non-empty validation
        /// - email: Basic email format validation
        ///
        /// Call this after init() to enable standard validation rules.
        pub fn registerValidators(self: *Validator(T)) !void {
            try self.engine.registerValidator("alpha", defaults.alphaValidator);
            try self.engine.registerValidator("numeric", defaults.numericValidator);
            try self.engine.registerValidator("min_length", defaults.minLengthValidator);
            try self.engine.registerValidator("max_length", defaults.maxLengthValidator);
            try self.engine.registerValidator("min", defaults.minValidator);
            try self.engine.registerValidator("max", defaults.maxValidator);
            try self.engine.registerValidator("required", defaults.requiredValidator);
            try self.engine.registerValidator("email", defaults.emailValidator);
        }

        /// Registers default error messages for built-in validators.
        ///
        /// Provides user-friendly error messages for each built-in validator.
        /// These messages are used when no custom message is specified in
        /// the validation documentation.
        ///
        /// Call this after registerValidators() to set up default messages.
        pub fn registerMessages(self: *Validator(T)) !void {
            try self.engine.registerDefaultMessage("alpha", "Field must contain only alphabetic characters");
            try self.engine.registerDefaultMessage("numeric", "Field must be numeric");
            try self.engine.registerDefaultMessage("min_length", "Field length is below minimum");
            try self.engine.registerDefaultMessage("max_length", "Field length exceeds maximum");
            try self.engine.registerDefaultMessage("min", "Value is below minimum");
            try self.engine.registerDefaultMessage("max", "Value exceeds maximum");
            try self.engine.registerDefaultMessage("required", "Field is required");
            try self.engine.registerDefaultMessage("email", "Invalid email format");
        }

        /// Registers a custom validator function.
        ///
        /// Allows extending validation with domain-specific rules beyond
        /// the built-in validators. The custom validator must match the
        /// ValidatorFn signature.
        ///
        /// Example:
        /// ```zig
        /// try validator.registerCustomValidator("phone", phoneValidator);
        /// ```
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

        /// Registers a custom error message for a validator.
        ///
        /// Overrides the default message for a specific validator,
        /// providing more context-specific error feedback.
        ///
        /// Example:
        /// ```zig
        /// try validator.registerCustomMessage("required", "Username cannot be empty");
        /// ```
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

        /// Validates a struct instance against its documentation.
        ///
        /// This is the main entry point for validation. It:
        /// 1. Extracts validation documentation from the struct type or parameter
        /// 2. Lexes and parses the documentation into specifications
        /// 3. Validates each field according to its specification
        /// 4. Recursively validates nested structs
        ///
        /// Documentation Resolution:
        /// - First checks for struct decl named "doc"
        /// - Falls back to "documentation" decl
        /// - Uses provided source parameter if available
        /// - Returns error if no documentation found
        ///
        /// Args:
        /// - container: The struct instance to validate
        /// - source: Optional external validation specification (overrides struct doc)
        ///
        /// Returns: void on success
        /// Errors:
        /// - InvalidContainer: If container is not a struct
        /// - MissingDocumentation: If no validation doc found
        /// - ValidationFailed: If any field fails validation
        pub fn validate(self: *Validator(T), container: T, source: ?[]const u8) !void {
            const container_type = @TypeOf(container);
            const container_info = @typeInfo(container_type);

            if (container_info == .pointer) {
                if (container_info.pointer.size == .one) {
                    return try self.validate(
                        container.*,
                        source,
                    );
                }
            }

            if (container_info != .@"struct") {
                return error.InvalidContainer;
            }

            const doc_source = blk: {
                const has_doc = @hasDecl(container_type, "doc");
                const has_documentation = @hasDecl(container_type, "documentation");

                if (has_doc) break :blk @field(container_type, "doc");
                if (has_documentation) break :blk @field(container_type, "documentation");

                inline for (container_info.@"struct".decls) |decl| {
                    if (comptime zstd.mem.eql(u8, decl.name, "doc")) {
                        break :blk @field(container_type, "doc");
                    }
                    if (comptime zstd.mem.eql(u8, decl.name, "documentation")) {
                        break :blk @field(container_type, "documentation");
                    }
                }

                if (source) |src| {
                    break :blk src;
                }

                return error.MissingDocumentation;
            };

            if (doc_source.len == 0) return;

            var l = try lexer.Lexer.init(self.allocator, doc_source);
            defer l.deinit();

            const tokens = try l.lex();
            var p = parser.Parser.init(self.allocator, tokens, doc_source);
            const validation_specs = try p.parse();
            defer validation_specs.deinit(self.allocator);

            try self.validateStruct(container, validation_specs);
        }

        /// Internal method that validates all fields in a struct.
        ///
        /// Iterates through struct fields, detecting:
        /// - Documentation fields (skipped)
        /// - Nested struct fields (recursively validated)
        /// - Regular fields (validated against specs)
        ///
        /// Nested struct validation creates isolated sub-validators with
        /// their own allocators but inherited validator registrations.
        fn validateStruct(
            self: *Validator(T),
            container: anytype,
            validation_specs: lexer.Documentation,
        ) !void {
            const container_type = @TypeOf(container);
            const container_info = @typeInfo(container_type);

            inline for (container_info.@"struct".fields) |field| {
                if (comptime zstd.mem.eql(u8, field.name, "doc") or
                    zstd.mem.eql(u8, field.name, "documentation"))
                {
                    continue;
                }

                const field_type_info = @typeInfo(field.type);
                if (field_type_info == .@"struct") {
                    const nested_value = @field(container, field.name);

                    const nested_doc = if (@hasDecl(field.type, "doc"))
                        @field(field.type, "doc")
                    else if (@hasDecl(field.type, "documentation"))
                        @field(field.type, "documentation")
                    else
                        "";
                    if (nested_doc.len > 0) {
                        {
                            var gpa = zstd.heap.DebugAllocator(.{}){};
                            defer zstd.debug.assert(gpa.deinit() == .ok);
                            const allocator = gpa.allocator();
                            var validator = try Validator(field.type).init(allocator);
                            defer validator.deinit();
                            validator.engine.validators = try self.copyValidators(allocator);
                            validator.engine.default_messages = try self.copyValidatorMessage(allocator);
                            try validator.validate(nested_value, nested_doc);
                        }
                    }
                    continue;
                }

                if (field_type_info == .pointer and
                    field_type_info.pointer.size == .one and
                    @typeInfo(field_type_info.pointer.child) == .@"struct")
                {
                    const Child = field_type_info.pointer.child;
                    const nested_ptr = @field(container, field.name);
                    const nested_doc = if (@hasDecl(Child, "doc"))
                        @field(Child, "doc")
                    else if (@hasDecl(Child, "documentation"))
                        @field(Child, "documentation")
                    else
                        "";
                    if (nested_doc.len > 0) {
                        var gpa = zstd.heap.DebugAllocator(.{}){};
                        defer zstd.debug.assert(gpa.deinit() == .ok);
                        const allocator = gpa.allocator();
                        var validator = try Validator(Child).init(allocator);
                        defer validator.deinit();
                        validator.engine.validators = try self.copyValidators(allocator);
                        validator.engine.default_messages = try self.copyValidatorMessage(allocator);
                        try validator.validate(nested_ptr.*, nested_doc);
                    }
                    continue;
                }

                try self.validateField(container, field, validation_specs);
            }
        }

        /// Validates a single field against its validation specification.
        ///
        /// Process:
        /// 1. Finds the validation spec matching the field name
        /// 2. Converts field value to string based on its type
        /// 3. Prepares validator and message lists
        /// 4. Executes validation engine
        /// 5. Reports first validation failure
        ///
        /// Type Conversion:
        /// - Integers: Formatted as decimal
        /// - Floats: Formatted as decimal
        /// - u8 slices: Treated as strings
        /// - Booleans: Formatted as true/false
        /// - Others: Generic {any} formatting
        ///
        /// Memory Management:
        /// - Uses stack buffer for value conversion (256 bytes)
        /// - Allocates temporary copies of validators and messages
        /// - Frees all allocations via defer blocks
        fn validateField(
            self: *Validator(T),
            container: anytype,
            field: zstd.builtin.Type.StructField,
            validation_specs: lexer.Documentation,
        ) !void {
            for (validation_specs.specs) |validation_spec| {
                if (!zstd.mem.eql(u8, validation_spec.property, field.name)) {
                    continue;
                }

                const field_value = @field(container, field.name);
                var value_buf: [256]u8 = undefined;
                const value = blk: {
                    const v = engine.Value.fromAny(field_value);
                    if (v != .other) break :blk v;
                    const s = try zstd.fmt.bufPrint(&value_buf, "{any}", .{field_value});
                    break :blk engine.Value{ .string = s };
                };

                var validators = try zstd.ArrayList(engine.Validator).initCapacity(self.allocator, 0);
                defer {
                    for (validators.items) |v| {
                        self.allocator.free(v.name);
                        for (v.params) |pm| {
                            if (pm.key) |_| {
                                self.allocator.free(pm.key.?);
                            }
                            self.allocator.free(pm.value);
                        }
                        self.allocator.free(v.params);
                    }
                    validators.deinit(self.allocator);
                }

                var messages = try zstd.ArrayList(engine.ValidationMessage).initCapacity(self.allocator, 0);
                defer {
                    for (messages.items) |m| {
                        self.allocator.free(m.name);
                    }
                    messages.deinit(self.allocator);
                }

                for (validation_spec.validators) |v| {
                    const validator_name = try self.allocator.dupe(u8, v.name);
                    errdefer self.allocator.free(validator_name);

                    var params = try self.allocator.alloc(engine.Parameter, v.params.len);
                    errdefer self.allocator.free(params);

                    for (v.params, 0..) |param, i| {
                        params[i] = engine.Parameter{
                            .key = if (param.key) |k| try self.allocator.dupe(u8, k) else null,
                            .value = try self.allocator.dupe(u8, param.value),
                        };
                    }

                    try validators.append(self.allocator, engine.Validator{
                        .name = validator_name,
                        .params = params,
                    });
                }

                for (validation_spec.messages) |msg| {
                    try messages.append(self.allocator, engine.ValidationMessage{
                        .name = try self.allocator.dupe(u8, msg.name),
                        .message = msg.message,
                    });
                }

                const results = try self.engine.validateField(
                    field.name,
                    value,
                    validators.items,
                    messages.items,
                );
                defer self.allocator.free(results);

                for (results) |result| {
                    if (!result.valid) {
                        zstd.debug.print("\nValidation failed for field '{s}': {s}\n", .{
                            field.name,
                            result.error_message orelse "Unknown error",
                        });
                        return error.ValidationFailed;
                    }
                }
            }
        }

        /// Creates a deep copy of the validator registry.
        ///
        /// Used when creating nested validators to inherit parent validator
        /// registrations without sharing the same HashMap instance.
        ///
        /// Args:
        /// - dest_allocator: Allocator for the new map and key copies
        ///
        /// Returns: New StringHashMap with duplicated keys and function pointers
        pub fn copyValidators(self: *Validator(T), dest_allocator: zstd.mem.Allocator) !zstd.StringHashMap(engine.ValidatorFn) {
            var new_map = zstd.StringHashMap(engine.ValidatorFn).init(dest_allocator);
            errdefer {
                var it = new_map.iterator();
                while (it.next()) |entry| {
                    dest_allocator.free(entry.key_ptr.*);
                }
                new_map.deinit();
            }

            var iterator = self.engine.validators.iterator();
            while (iterator.next()) |entry| {
                const key_copy = try dest_allocator.dupe(u8, entry.key_ptr.*);
                errdefer dest_allocator.free(key_copy);
                try new_map.put(key_copy, entry.value_ptr.*);
            }

            return new_map;
        }

        /// Creates a deep copy of the default messages registry.
        ///
        /// Used when creating nested validators to inherit parent message
        /// definitions without sharing the same HashMap instance.
        ///
        /// Args:
        /// - dest_allocator: Allocator for the new map, keys, and values
        ///
        /// Returns: New StringHashMap with duplicated keys and message strings
        pub fn copyValidatorMessage(self: *Validator(T), dest_allocator: zstd.mem.Allocator) !zstd.StringHashMap([]const u8) {
            var new_map = zstd.StringHashMap([]const u8).init(dest_allocator);
            errdefer {
                var it = new_map.iterator();
                while (it.next()) |entry| {
                    dest_allocator.free(entry.key_ptr.*);
                    dest_allocator.free(entry.value_ptr.*);
                }
                new_map.deinit();
            }

            var iterator = self.engine.default_messages.iterator();
            while (iterator.next()) |entry| {
                const key_copy = try dest_allocator.dupe(u8, entry.key_ptr.*);
                errdefer dest_allocator.free(key_copy);
                const value_copy = try dest_allocator.dupe(u8, entry.value_ptr.*);
                errdefer dest_allocator.free(value_copy);
                try new_map.put(key_copy, value_copy);
            }

            return new_map;
        }
    };
}

test "validator with registration functions" {
    const allocator = zstd.testing.allocator;
    var validator = try Validator(i32).init(allocator);
    defer validator.deinit();

    try validator.registerValidators();
    try validator.registerMessages();

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

    try validator.registerValidators();
    try validator.registerMessages();

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

                var suffixes = zstd.mem.splitSequence(u8, context.params[0].value, ",");
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
                    .{context.params[0].value},
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

    try validator.registerValidators();
    try validator.registerMessages();

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

    try validator.registerValidators();
    try validator.registerMessages();

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

    const tmp_dir = zstd.testing.tmpDir(.{});
    var dir = tmp_dir.dir;

    try dir.writeFile(.{
        .data = env_content,
        .sub_path = "complex.env",
    });
    defer dir.deleteFile("complex.env") catch {};

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
    defer env_parser.deinit(config);

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
    try vd.registerValidators();
    try vd.registerMessages();
    try vd.registerCustomValidator("url", struct {
        fn url_validator(ctx: engine.Context) engine.ValidationError!engine.ValidationResult {
            const s = ctx.value.asString() orelse {
                return engine.ValidationResult.failure("Failed to validate URL format");
            };
            var regex_t: clib.regex_t = undefined;
            const regex_pattern = "^(https?|ftp|postgres|redis)://[^[:space:]]+$";
            defer clib.regfree(&regex_t);
            const success = clib.regcomp(
                &regex_t,
                regex_pattern,
                clib.REG_EXTENDED | clib.REG_NOSUB,
            );
            const error_msg = "Failed to validate URL format";
            if (success != 0) {
                return engine.ValidationResult.failure(error_msg);
            }
            const match = clib.regexec(&regex_t, s.ptr, 0, null, 0);
            if (match == 0) {
                return engine.ValidationResult.success();
            } else {
                return engine.ValidationResult.failure(error_msg);
            }
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

    const tmp_dir = zstd.testing.tmpDir(.{});
    var dir = tmp_dir.dir;

    try dir.writeFile(.{
        .data = env_content,
        .sub_path = "invalid.env",
    });
    defer dir.deleteFile("invalid.env") catch {};

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
    defer env_parser.deinit(config);

    var vd = try Validator(Config).init(allocator);
    defer vd.deinit();
    try vd.registerValidators();
    try vd.registerMessages();

    try zstd.testing.expectError(error.ValidationFailed, vd.validate(config.*, null));
}
