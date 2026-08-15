const zstd = @import("std");

fn startsWithAt(source: []const u8, index: usize, sequence: []const u8) bool {
    return index + sequence.len <= source.len and
        zstd.mem.eql(u8, source[index .. index + sequence.len], sequence);
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@';
}

fn isIdentContinue(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn isDigitChar(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn identifyKeyword(lexeme: []const u8) TokenType {
    if (lexeme.len > 0 and lexeme[0] == '@') return .value_tag;
    return switch (lexeme.len) {
        8 => blk: {
            if (zstd.mem.eql(u8, lexeme, "property")) break :blk .property_tag;
            if (zstd.mem.eql(u8, lexeme, "messages")) break :blk .messages_tag;
            break :blk .identifier;
        },
        9 => if (zstd.mem.eql(u8, lexeme, "validator")) .validator_tag else .identifier,
        10 => if (zstd.mem.eql(u8, lexeme, "validation")) .validation_tag else .identifier,
        else => .identifier,
    };
}

pub const TokenType = enum {
    comment_tag,
    property_tag,
    validator_tag,
    messages_tag,
    validation_tag,
    value_tag,
    colon,
    identifier,
    comma,
    equals,
    dash,
    string_literal,
    newline,
    number,
    eof,
};

pub const Token = struct {
    token_type: TokenType,
    start: usize,
    end: usize,

    pub fn length(self: Token) usize {
        return self.end - self.start;
    }

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const Lexer = struct {
    source: []const u8,
    allocator: zstd.mem.Allocator,
    tokens: zstd.ArrayList(Token),

    pub fn init(allocator: zstd.mem.Allocator, source: []const u8) !Lexer {
        const estimated = @max(8, source.len / 4);
        return .{
            .allocator = allocator,
            .source = source,
            .tokens = try zstd.ArrayList(Token).initCapacity(allocator, estimated),
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    fn createToken(token_type: TokenType, start: usize, end: usize) Token {
        return .{
            .end = end,
            .start = start,
            .token_type = token_type,
        };
    }

    fn skipWhitespace(source: []const u8, index: *usize) void {
        while (index.* < source.len) {
            const ch = source[index.*];
            if (ch != ' ' and ch != '\t') break;
            index.* += 1;
        }
    }

    pub fn lex(self: *Lexer) ![]Token {
        const source = self.source;
        var i: usize = 0;

        while (i < source.len) {
            const c = source[i];

            if (c == ' ' or c == '\t') {
                skipWhitespace(source, &i);
                continue;
            }

            if (c == '\n') {
                try self.tokens.append(self.allocator, createToken(.newline, i, i + 1));
                i += 1;
                continue;
            }

            if (startsWithAt(source, i, "//")) {
                i += if (startsWithAt(source, i, "///")) @as(usize, 3) else 2;
                skipWhitespace(source, &i);

                if (i >= source.len or source[i] != '@') {
                    const line_start = i;
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                    if (i > line_start) {
                        try self.tokens.append(
                            self.allocator,
                            createToken(.comment_tag, line_start, i),
                        );
                    }
                    continue;
                }

                i += 1;
                continue;
            }

            switch (c) {
                ':' => {
                    try self.tokens.append(self.allocator, createToken(.colon, i, i + 1));
                    i += 1;
                },
                '=' => {
                    try self.tokens.append(self.allocator, createToken(.equals, i, i + 1));
                    i += 1;
                },
                '-' => {
                    try self.tokens.append(self.allocator, createToken(.dash, i, i + 1));
                    i += 1;
                },
                ',' => {
                    try self.tokens.append(self.allocator, createToken(.comma, i, i + 1));
                    i += 1;
                },
                '"' => {
                    i += 1;
                    const str_start = i;
                    while (i < source.len and source[i] != '"') : (i += 1) {}
                    try self.tokens.append(
                        self.allocator,
                        createToken(.string_literal, str_start, i),
                    );
                    if (i < source.len and source[i] == '"') i += 1;
                },
                else => {
                    if (isIdentStart(c)) {
                        const id_start = i;
                        i += 1;
                        while (i < source.len and isIdentContinue(source[i])) : (i += 1) {}
                        try self.tokens.append(self.allocator, .{
                            .token_type = identifyKeyword(source[id_start..i]),
                            .start = id_start,
                            .end = i,
                        });
                    } else if (isDigitChar(c) or c == '.') {
                        const num_start = i;
                        i += 1;
                        while (i < source.len and (isDigitChar(source[i]) or source[i] == '.')) : (i += 1) {}
                        try self.tokens.append(
                            self.allocator,
                            createToken(.number, num_start, i),
                        );
                    } else {
                        i += 1;
                    }
                },
            }
        }

        try self.tokens.append(self.allocator, .{
            .token_type = .eof,
            .start = i,
            .end = i,
        });

        return self.tokens.items;
    }
};

pub const Parameter = struct {
    key: ?[]const u8,
    value: []const u8,
};

pub const Validator = struct {
    name: []const u8,
    params: []Parameter,

    pub fn deinit(self: Validator, allocator: zstd.mem.Allocator) void {
        if (self.params.len > 0) {
            allocator.free(self.params);
        }
    }
};

pub const ValidationMessage = struct {
    name: []const u8,
    message: []const u8,
};

pub const Specification = struct {
    doc: []const u8,
    property: []const u8,
    validators: []Validator,
    messages: []ValidationMessage,

    pub fn deinit(self: Specification, allocator: zstd.mem.Allocator) void {
        if (self.doc.len > 0) {
            allocator.free(self.doc);
        }
        for (self.validators) |validator| {
            validator.deinit(allocator);
        }
        allocator.free(self.validators);
        allocator.free(self.messages);
    }

    pub fn print(self: Specification) void {
        zstd.debug.print("Property: {s}\n\n", .{self.property});

        if (self.doc.len > 0) {
            zstd.debug.print("Documentation:\n", .{});
            zstd.debug.print("{s}\n\n", .{self.doc});
        }

        if (self.validators.len > 0) {
            zstd.debug.print("Validators:\n", .{});
            for (self.validators) |validator| {
                zstd.debug.print("  • @{s}", .{validator.name});
                if (validator.params.len > 0) {
                    zstd.debug.print(" = ", .{});
                    for (validator.params, 0..) |param, i| {
                        if (param.key) |key| {
                            zstd.debug.print("{s}:", .{key});
                        }

                        zstd.debug.print("{s}", .{param.value});
                        if (i < validator.params.len - 1) {
                            zstd.debug.print(", ", .{});
                        }
                    }
                }
                zstd.debug.print("\n", .{});
            }
            zstd.debug.print("\n", .{});
        }

        if (self.messages.len > 0) {
            zstd.debug.print("Error Messages:\n", .{});
            for (self.messages) |message| {
                zstd.debug.print("  • {s}: \"{s}\"\n", .{ message.name, message.message });
            }
        }
    }
};

pub const Documentation = struct {
    specs: []Specification,

    pub fn deinit(self: Documentation, allocator: zstd.mem.Allocator) void {
        for (self.specs) |spec| {
            spec.deinit(allocator);
        }
        allocator.free(self.specs);
    }

    pub fn print(self: Documentation) void {
        zstd.debug.print("\n{s}\n", .{"=" ** 80});
        zstd.debug.print("VALIDATION DOCUMENTATION\n", .{});
        zstd.debug.print("{s}\n\n", .{"=" ** 80});

        for (self.specs, 0..) |spec, i| {
            zstd.debug.print("SPECIFICATION #{d}\n", .{i + 1});
            zstd.debug.print("{s}\n\n", .{"-" ** 80});
            spec.print();
            zstd.debug.print("\n", .{});
        }

        zstd.debug.print("{s}\n", .{"=" ** 80});
    }
};

pub const ValidationEngine = struct {
    source: []const u8,
};

test "lexer" {
    const Test = struct {
        name: []const u8,
        source: []const u8,
        expected: []const Token,
        test_fn: *const fn (allocator: zstd.mem.Allocator, src: []const u8, expected: []const Token) anyerror!void,
    };

    const testcases: []const Test = &.{
        Test{
            .name = "Parse Comment",
            .source = "// User type allows to store user",
            .expected = &.{
                Token{ .token_type = .comment_tag, .start = 3, .end = 33 },
                Token{ .token_type = .eof, .start = 33, .end = 33 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens.len > 0);
                    try zstd.testing.expect(tokens[0].token_type == .comment_tag);
                    try zstd.testing.expect(tokens[tokens.len - 1].token_type == .eof);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Validator Tag",
            .source =
            \\// This struct represents a user account with validation
            \\// @validation
            ,
            .expected = &.{
                Token{ .token_type = .comment_tag, .start = 3, .end = 56 },
                Token{ .token_type = .newline, .start = 56, .end = 57 },
                Token{ .token_type = .validation_tag, .start = 61, .end = 71 },
                Token{ .token_type = .eof, .start = 71, .end = 71 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens.len == 4);
                    try zstd.testing.expect(tokens[2].token_type == .validation_tag);
                    try zstd.testing.expect(tokens[3].token_type == .eof);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Field with Validator",
            .source =
            \\// @validation
            \\// @property: name
            \\//   @validator: @alpha,@min_length=24
            ,
            .expected = &.{
                Token{ .token_type = .validation_tag, .start = 4, .end = 14 },
                Token{ .token_type = .newline, .start = 14, .end = 15 },
                Token{ .token_type = .property_tag, .start = 19, .end = 27 },
                Token{ .token_type = .colon, .start = 27, .end = 28 },
                Token{ .token_type = .identifier, .start = 29, .end = 33 },
                Token{ .token_type = .newline, .start = 33, .end = 34 },
                Token{ .token_type = .validator_tag, .start = 40, .end = 49 },
                Token{ .token_type = .colon, .start = 49, .end = 50 },
                Token{ .token_type = .value_tag, .start = 51, .end = 57 },
                Token{ .token_type = .comma, .start = 57, .end = 58 },
                Token{ .token_type = .value_tag, .start = 58, .end = 69 },
                Token{ .token_type = .equals, .start = 69, .end = 70 },
                Token{ .token_type = .number, .start = 70, .end = 72 },
                Token{ .token_type = .eof, .start = 72, .end = 72 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Messages Section",
            .source =
            \\//  @messages:
            \\//     @alpha - "Must be alphabetic only"
            ,
            .expected = &.{
                Token{ .token_type = .messages_tag, .start = 5, .end = 13 },
                Token{ .token_type = .colon, .start = 13, .end = 14 },
                Token{ .token_type = .newline, .start = 14, .end = 15 },
                Token{ .token_type = .identifier, .start = 23, .end = 28 },
                Token{ .token_type = .dash, .start = 29, .end = 30 },
                Token{ .token_type = .string_literal, .start = 32, .end = 55 },
                Token{ .token_type = .eof, .start = 56, .end = 56 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens[0].token_type == .messages_tag);
                    try zstd.testing.expect(tokens[5].token_type == .string_literal);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Email Validator with Multiple Endings",
            .source =
            \\// @property: email
            \\//   @validator: @email,@endswith=".com,.it,.edu"
            ,
            .expected = &.{
                Token{ .token_type = .property_tag, .start = 4, .end = 12 },
                Token{ .token_type = .colon, .start = 12, .end = 13 },
                Token{ .token_type = .identifier, .start = 14, .end = 19 },
                Token{ .token_type = .newline, .start = 19, .end = 20 },
                Token{ .token_type = .validator_tag, .start = 26, .end = 35 },
                Token{ .token_type = .colon, .start = 35, .end = 36 },
                Token{ .token_type = .value_tag, .start = 37, .end = 43 },
                Token{ .token_type = .comma, .start = 43, .end = 44 },
                Token{ .token_type = .value_tag, .start = 44, .end = 53 },
                Token{ .token_type = .equals, .start = 53, .end = 54 },
                Token{ .token_type = .string_literal, .start = 55, .end = 68 },
                Token{ .token_type = .eof, .start = 69, .end = 69 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens[6].token_type == .value_tag);
                    try zstd.testing.expect(tokens[8].token_type == .value_tag);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Complete Validation Block",
            .source =
            \\// @validation
            \\// @property:  age
            \\//   @validator: @numeric,@min=10
            \\//   @messages:
            \\//     @min: "Age must be at least 10"
            ,
            .expected = &.{
                Token{ .token_type = .validation_tag, .start = 4, .end = 14 },
                Token{ .token_type = .newline, .start = 14, .end = 15 },
                Token{ .token_type = .property_tag, .start = 19, .end = 27 },
                Token{ .token_type = .colon, .start = 27, .end = 28 },
                Token{ .token_type = .identifier, .start = 30, .end = 33 },
                Token{ .token_type = .newline, .start = 33, .end = 34 },
                Token{ .token_type = .validator_tag, .start = 40, .end = 49 },
                Token{ .token_type = .colon, .start = 49, .end = 50 },
                Token{ .token_type = .value_tag, .start = 51, .end = 59 },
                Token{ .token_type = .comma, .start = 59, .end = 60 },
                Token{ .token_type = .value_tag, .start = 60, .end = 64 },
                Token{ .token_type = .equals, .start = 64, .end = 65 },
                Token{ .token_type = .number, .start = 65, .end = 67 },
                Token{ .token_type = .newline, .start = 67, .end = 68 },
                Token{ .token_type = .messages_tag, .start = 74, .end = 82 },
                Token{ .token_type = .colon, .start = 82, .end = 83 },
                Token{ .token_type = .newline, .start = 83, .end = 84 },
                Token{ .token_type = .identifier, .start = 92, .end = 95 },
                Token{ .token_type = .colon, .start = 95, .end = 96 },
                Token{ .token_type = .string_literal, .start = 98, .end = 121 },
                Token{ .token_type = .eof, .start = 122, .end = 122 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Empty Source",
            .source = "",
            .expected = &.{
                Token{
                    .token_type = .eof,
                    .start = 0,
                    .end = 0,
                },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens.len == 1);
                    try zstd.testing.expect(tokens[0].token_type == .eof);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
        Test{
            .name = "Parse Multiple Newlines",
            .source =
            \\// comment
            \\
            \\// another comment
            ,
            .expected = &.{
                Token{ .token_type = .comment_tag, .start = 3, .end = 10 },
                Token{ .token_type = .newline, .start = 10, .end = 11 },
                Token{ .token_type = .newline, .start = 11, .end = 12 },
                Token{ .token_type = .comment_tag, .start = 15, .end = 30 },
                Token{ .token_type = .eof, .start = 30, .end = 30 },
            },
            .test_fn = struct {
                fn executor(allocator: zstd.mem.Allocator, source: []const u8, expected: []const Token) anyerror!void {
                    var lexer = try Lexer.init(allocator, source);
                    defer lexer.deinit();
                    const tokens = try lexer.lex();
                    try zstd.testing.expect(tokens[1].token_type == .newline);
                    try zstd.testing.expect(tokens[2].token_type == .newline);
                    try zstd.testing.expectEqualSlices(Token, expected, tokens);
                }
            }.executor,
        },
    };

    const allocator = zstd.testing.allocator;

    for (0..testcases.len) |idx| {
        var testcase = testcases[idx];
        try testcase.test_fn(
            allocator,
            testcase.source,
            testcase.expected,
        );
    }
}
