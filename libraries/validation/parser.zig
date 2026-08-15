const zstd = @import("std");
const lex = @import("./lexer.zig");
const Lexer = lex.Lexer;
const Token = lex.Token;
const TokenType = lex.TokenType;
const Documentation = lex.Documentation;
const Specification = lex.Specification;
const Validator = lex.Validator;
const ValidationMessage = lex.ValidationMessage;
const Parameter = lex.Parameter;

pub const Parser = struct {
    tokens: []const Token,
    allocator: zstd.mem.Allocator,
    source: []const u8,
    index: usize = 0,

    pub fn init(allocator: zstd.mem.Allocator, tokens: []const Token, source: []const u8) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .source = source,
            .index = 0,
        };
    }

    fn current(self: *const Parser) ?Token {
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index];
    }

    fn advance(self: *Parser) ?Token {
        if (self.index >= self.tokens.len) return null;
        const token = self.tokens[self.index];
        self.index += 1;
        return token;
    }

    fn expect(self: *Parser, token_type: TokenType) !Token {
        const token = self.advance() orelse return error.UnexpectedEOF;
        if (token.token_type != token_type) {
            return error.UnexpectedToken;
        }
        return token;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.current()) |token| {
            if (token.token_type != .newline) break;
            _ = self.advance();
        }
    }

    fn emitSpec(
        self: *Parser,
        specs: *zstd.ArrayList(Specification),
        documentation: *zstd.ArrayList([]const u8),
        property: []const u8,
        validators: *zstd.ArrayList(Validator),
        messages: *zstd.ArrayList(ValidationMessage),
    ) !void {
        if (validators.items.len == 0 and messages.items.len == 0) {
            documentation.clearRetainingCapacity();
            return;
        }

        const doc = if (documentation.items.len == 0)
            @as([]const u8, "")
        else
            try zstd.mem.join(self.allocator, "\n", documentation.items);
        errdefer if (doc.len > 0) self.allocator.free(doc);

        const validators_slice = try self.allocator.dupe(Validator, validators.items);
        errdefer self.allocator.free(validators_slice);

        const messages_slice = try self.allocator.dupe(ValidationMessage, messages.items);
        errdefer self.allocator.free(messages_slice);

        try specs.append(self.allocator, .{
            .doc = doc,
            .property = property,
            .validators = validators_slice,
            .messages = messages_slice,
        });

        documentation.clearRetainingCapacity();
        validators.clearRetainingCapacity();
        messages.clearRetainingCapacity();
    }

    pub fn parse(self: *Parser) !Documentation {
        const estimated_specs = @max(1, self.tokens.len / 16);
        var specs = try zstd.ArrayList(Specification).initCapacity(self.allocator, estimated_specs);
        var validators = try zstd.ArrayList(Validator).initCapacity(self.allocator, 8);
        var messages = try zstd.ArrayList(ValidationMessage).initCapacity(self.allocator, 8);
        var documentation = try zstd.ArrayList([]const u8).initCapacity(self.allocator, 4);
        var property: ?[]const u8 = null;
        var in_validation_block = false;

        errdefer {
            for (specs.items) |spec| {
                spec.deinit(self.allocator);
            }
            for (validators.items) |validator| {
                validator.deinit(self.allocator);
            }
            specs.deinit(self.allocator);
            validators.deinit(self.allocator);
            messages.deinit(self.allocator);
            documentation.deinit(self.allocator);
        }

        while (self.current()) |token| {
            switch (token.token_type) {
                .eof => break,
                .newline => {
                    _ = self.advance();
                },
                .comment_tag => {
                    try documentation.append(self.allocator, token.lexeme(self.source));
                    _ = self.advance();
                },
                .validation_tag => {
                    _ = self.advance();
                    in_validation_block = true;
                    self.skipNewlines();
                },
                .property_tag => {
                    _ = self.advance();
                    _ = try self.expect(.colon);
                    const name_token = try self.expect(.identifier);
                    const name = name_token.lexeme(self.source);

                    if (in_validation_block and property != null) {
                        try self.emitSpec(
                            &specs,
                            &documentation,
                            property.?,
                            &validators,
                            &messages,
                        );
                    }

                    property = name;
                    self.skipNewlines();
                },
                .validator_tag => {
                    if (property == null) return error.InvalidToken;
                    _ = self.advance();
                    _ = try self.expect(.colon);
                    try self.parseValidators(&validators);
                    self.skipNewlines();
                },
                .messages_tag => {
                    _ = self.advance();
                    _ = try self.expect(.colon);
                    self.skipNewlines();
                    try self.parseMessages(&messages);
                },
                else => {
                    _ = self.advance();
                },
            }
        }

        if (in_validation_block and property != null) {
            try self.emitSpec(
                &specs,
                &documentation,
                property.?,
                &validators,
                &messages,
            );
        }

        documentation.deinit(self.allocator);
        validators.deinit(self.allocator);
        messages.deinit(self.allocator);

        return Documentation{
            .specs = try specs.toOwnedSlice(self.allocator),
        };
    }

    fn parseValidators(
        self: *Parser,
        validators: *zstd.ArrayList(Validator),
    ) !void {
        while (self.current()) |token| {
            if (token.token_type != .value_tag) break;

            const validator_token = self.advance().?;
            const validator_name = validator_token.lexeme(self.source);
            const name = if (validator_name.len > 0 and validator_name[0] == '@')
                validator_name[1..]
            else
                validator_name;

            var params: []Parameter = &.{};
            if (self.current()) |next| {
                if (next.token_type == .equals) {
                    _ = self.advance();

                    const value_token = self.advance() orelse return error.MissingValue;
                    const value = switch (value_token.token_type) {
                        .number, .string_literal, .identifier => value_token.lexeme(self.source),
                        else => return error.InvalidValue,
                    };

                    const owned = try self.allocator.alloc(Parameter, 1);
                    owned[0] = .{
                        .key = null,
                        .value = value,
                    };
                    params = owned;
                }
            }

            try validators.append(self.allocator, .{
                .name = name,
                .params = params,
            });

            if (self.current()) |next| {
                if (next.token_type == .comma) {
                    _ = self.advance();
                } else {
                    break;
                }
            }
        }
    }

    fn parseMessages(
        self: *Parser,
        messages: *zstd.ArrayList(ValidationMessage),
    ) !void {
        while (self.current()) |token| {
            if (token.token_type != .identifier) break;

            const name_token = self.advance().?;
            const validator_name = name_token.lexeme(self.source);

            const sep = self.current() orelse break;
            if (sep.token_type != .dash and sep.token_type != .colon) break;
            _ = self.advance();

            const msg_token = try self.expect(.string_literal);

            try messages.append(self.allocator, .{
                .name = validator_name,
                .message = msg_token.lexeme(self.source),
            });

            self.skipNewlines();
        }
    }
};

test "parser" {
    const allocator = zstd.testing.allocator;
    const validation_comment =
        \\// User type allows to store user
        \\// This struct represents a user account with validation
        \\// @validation
        \\// @property: name
        \\//   @validator: @alpha,@min_length=24,@max_length=56
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
    var lexer = try Lexer.init(
        allocator,
        validation_comment,
    );
    defer lexer.deinit();
    const tokens = try lexer.lex();

    var parser = Parser.init(
        allocator,
        tokens,
        validation_comment,
    );
    const documentation = try parser.parse();
    defer documentation.deinit(allocator);

    documentation.print();
    try zstd.testing.expectEqual(@as(usize, 3), documentation.specs.len);
    try zstd.testing.expectEqualStrings("name", documentation.specs[0].property);
    try zstd.testing.expectEqual(@as(usize, 3), documentation.specs[0].validators.len);
    try zstd.testing.expectEqual(@as(usize, 3), documentation.specs[0].messages.len);
    try zstd.testing.expectEqualStrings("age", documentation.specs[1].property);
    try zstd.testing.expectEqual(@as(usize, 3), documentation.specs[1].validators.len);
    try zstd.testing.expectEqualStrings("email", documentation.specs[2].property);
}

test "parser usage on struct" {
    const allocator = zstd.testing.allocator;

    const User = struct {
        const documentation =
            \\// @validation
            \\// @property: name
            \\//   @validator: @alpha,@min_length=3,@max_length=50
            \\//   @messages:
            \\//     alpha - "Name must be alphabetic only"
            \\//     min_length - "Name must be at least 3 characters"
            \\//     max_length - "Name cannot exceed 50 characters"
            \\// @validation
            \\// @property: age
            \\//   @validator: @numeric,@min=10,@max=130
            \\//   @messages:
            \\//     numeric - "Age must be numeric"
            \\//     min - "Age must be at least 10"
            \\//     max - "Age cannot exceed 130"
            \\// @validation
            \\// @property: time
            \\//   @validator: @required
            \\//   @messages:
            \\//     required - "Time is required"
        ;

        name: []const u8,
        age: i32,
        time: i64,
    };

    const source = User.documentation;
    var lexer = try Lexer.init(allocator, source);
    defer lexer.deinit();
    const tokens = try lexer.lex();

    var parser = Parser.init(allocator, tokens, source);
    const doc = try parser.parse();
    defer doc.deinit(allocator);

    const info = @typeInfo(User).@"struct";

    var field_specs = zstd.StringHashMap(*const Specification).init(allocator);
    defer field_specs.deinit();

    for (doc.specs) |*spec| {
        try field_specs.put(spec.property, spec);
    }

    var validated_count: usize = 0;
    var missing_count: usize = 0;

    inline for (info.fields) |field| {
        if (comptime zstd.mem.eql(u8, field.name, "documentation")) {
            continue;
        }

        if (field_specs.get(field.name)) |spec| {
            for (spec.validators) |validator| {
                if (validator.params.len > 0) {
                    for (validator.params, 0..) |_, i| {
                        if (i < validator.params.len - 1) zstd.debug.print(",", .{});
                    }
                }
            }
            validated_count += 1;
        } else {
            missing_count += 1;
        }
    }

    var orphaned_specs: usize = 0;

    for (doc.specs) |spec| {
        var found = false;
        inline for (info.fields) |field| {
            if (comptime zstd.mem.eql(u8, field.name, "documentation")) continue;
            if (zstd.mem.eql(u8, field.name, spec.property)) {
                found = true;
                break;
            }
        }

        if (!found) {
            orphaned_specs += 1;
        }
    }
    doc.print();

    try zstd.testing.expectEqual(@as(usize, 3), doc.specs.len);
    try zstd.testing.expectEqual(@as(usize, 3), validated_count);
    try zstd.testing.expectEqual(@as(usize, 0), missing_count);
    try zstd.testing.expectEqual(@as(usize, 0), orphaned_specs);
}
