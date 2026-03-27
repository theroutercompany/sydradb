const std = @import("std");
const common = @import("common.zig");
const frontend_diagnostics = @import("frontend/diagnostics.zig");

/// TokenKind enumerates lexical categories. Operators and symbols remain
/// granular so the parser can reason about precedence without string compares.
pub const TokenKind = enum {
    identifier,
    quoted_identifier,
    number,
    string,
    duration,
    timestamp,
    parameter,
    keyword,
    comma,
    period,
    semicolon,
    colon,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    equal,
    bang_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    regex_match,
    regex_not_match,
    and_and,
    or_or,
    arrow,
    eof,
    unknown,
};

/// Recognised sydraQL keywords.
pub const Keyword = enum {
    select,
    from,
    where,
    group,
    by,
    fill,
    order,
    limit,
    offset,
    insert,
    into,
    values,
    delete,
    explain,
    as,
    tag,
    time,
    now,
    between,
    logical_and,
    logical_or,
    logical_not,
    previous,
    linear,
    asc,
    desc,
    boolean_true,
    boolean_false,
    null_literal,
};

pub const ParameterKind = enum {
    positional,
    named,
};

pub const Parameter = struct {
    kind: ParameterKind,
    index: ?u32 = null,
    name: ?[]const u8 = null,
};

pub const LiteralClass = enum {
    plain,
    duration,
    timestamp,
};

/// Token captures the raw slice for a lexeme alongside its kind and span. For
/// keywords we also surface the resolved enum via `keyword`.
pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    span: common.Span,
    keyword: ?Keyword = null,
    fallback_kind: ?TokenKind = null,
    parameter: ?Parameter = null,
    literal_class: LiteralClass = .plain,

    pub fn canFallbackToIdentifier(self: Token) bool {
        return self.fallback_kind == .identifier;
    }

    pub fn isIdentifierLike(self: Token) bool {
        return self.kind == .identifier or self.kind == .quoted_identifier or self.canFallbackToIdentifier();
    }

    pub fn matchesKeyword(self: Token, keyword: Keyword) bool {
        return self.kind == .keyword and self.keyword != null and self.keyword.? == keyword;
    }
};

/// Lexer errors are returned for malformed literals (e.g. unterminated strings).
pub const LexError = error{
    InvalidLiteral,
    UnterminatedString,
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .allocator = allocator,
            .source = source,
            .index = 0,
        };
    }

    pub fn next(self: *Lexer) LexError!Token {
        self.skipWhitespaceAndComments();
        if (self.index >= self.source.len) {
            return eofToken(self.source.len);
        }

        const start = self.index;
        const ch = self.source[self.index];

        if (isIdentifierStart(ch)) {
            return self.scanIdentifier(start);
        }
        if (ch == '"' or ch == '\'') {
            return self.scanString(start, ch);
        }
        if (isDigit(ch)) {
            return self.scanNumber(start);
        }

        switch (ch) {
            ',' => return self.makeSimpleToken(TokenKind.comma, start, 1),
            '.' => return self.makeSimpleToken(TokenKind.period, start, 1),
            ';' => return self.makeSimpleToken(TokenKind.semicolon, start, 1),
            ':' => {
                if (self.index + 1 < self.source.len and isIdentifierStart(self.source[self.index + 1])) {
                    return self.scanParameter(start, .named);
                }
                return self.makeSimpleToken(TokenKind.colon, start, 1);
            },
            '(' => return self.makeSimpleToken(TokenKind.l_paren, start, 1),
            ')' => return self.makeSimpleToken(TokenKind.r_paren, start, 1),
            '[' => return self.makeSimpleToken(TokenKind.l_bracket, start, 1),
            ']' => return self.makeSimpleToken(TokenKind.r_bracket, start, 1),
            '{' => return self.makeSimpleToken(TokenKind.l_brace, start, 1),
            '}' => return self.makeSimpleToken(TokenKind.r_brace, start, 1),
            '+' => return self.makeSimpleToken(TokenKind.plus, start, 1),
            '-' => {
                if (self.matchChar('>')) {
                    return self.makeSimpleToken(TokenKind.arrow, start, 2);
                }
                return self.makeSimpleToken(TokenKind.minus, start, 1);
            },
            '*' => return self.makeSimpleToken(TokenKind.star, start, 1),
            '/' => return self.makeSimpleToken(TokenKind.slash, start, 1),
            '%' => return self.makeSimpleToken(TokenKind.percent, start, 1),
            '$' => {
                if (self.index + 1 < self.source.len and (isIdentifierStart(self.source[self.index + 1]) or isDigit(self.source[self.index + 1]))) {
                    return self.scanParameter(start, if (isDigit(self.source[self.index + 1])) .positional else .named);
                }
                return self.makeSimpleToken(TokenKind.unknown, start, 1);
            },
            '^' => return self.makeSimpleToken(TokenKind.caret, start, 1),
            '=' => {
                if (self.matchChar('~')) {
                    return self.makeSimpleToken(TokenKind.regex_match, start, 2);
                }
                return self.makeSimpleToken(TokenKind.equal, start, 1);
            },
            '!' => {
                if (self.matchChar('=')) {
                    return self.makeSimpleToken(TokenKind.bang_equal, start, 2);
                }
                if (self.matchChar('~')) {
                    return self.makeSimpleToken(TokenKind.regex_not_match, start, 2);
                }
                return self.makeSimpleToken(TokenKind.unknown, start, 1);
            },
            '<' => {
                if (self.matchChar('=')) {
                    return self.makeSimpleToken(TokenKind.less_equal, start, 2);
                }
                return self.makeSimpleToken(TokenKind.less, start, 1);
            },
            '>' => {
                if (self.matchChar('=')) {
                    return self.makeSimpleToken(TokenKind.greater_equal, start, 2);
                }
                return self.makeSimpleToken(TokenKind.greater, start, 1);
            },
            '&' => {
                if (self.matchChar('&')) {
                    return self.makeSimpleToken(TokenKind.and_and, start, 2);
                }
                return self.makeSimpleToken(TokenKind.unknown, start, 1);
            },
            '|' => {
                if (self.matchChar('|')) {
                    return self.makeSimpleToken(TokenKind.or_or, start, 2);
                }
                return self.makeSimpleToken(TokenKind.unknown, start, 1);
            },
            else => {},
        }

        self.index += 1;
        return Token{
            .kind = TokenKind.unknown,
            .lexeme = self.source[start..self.index],
            .span = common.Span.init(start, self.index),
            .keyword = null,
        };
    }

    pub fn peek(self: *Lexer) LexError!Token {
        const saved = self.index;
        const token = self.next() catch |err| {
            self.index = saved;
            return err;
        };
        self.index = saved;
        return token;
    }

    pub fn reset(self: *Lexer) void {
        self.index = 0;
    }

    pub fn collectAll(self: *Lexer, allocator: std.mem.Allocator) LexError![]Token {
        var tokens = std.array_list.Managed(Token).init(allocator);
        errdefer tokens.deinit();

        while (true) {
            const token = try self.next();
            try tokens.append(token);
            if (token.kind == .eof) break;
        }
        return try tokens.toOwnedSlice();
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.index < self.source.len) {
            const ch = self.source[self.index];
            switch (ch) {
                ' ', '\t', '\n', '\r' => {
                    self.index += 1;
                },
                '-' => {
                    if (self.matchAhead("--")) {
                        self.index += 2;
                        self.skipLineComment();
                        continue;
                    }
                    return;
                },
                '/' => {
                    if (self.matchAhead("/*")) {
                        self.index += 2;
                        self.skipBlockComment();
                        continue;
                    }
                    return;
                },
                else => return,
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        while (self.index < self.source.len and self.source[self.index] != '\n') {
            self.index += 1;
        }
    }

    fn skipBlockComment(self: *Lexer) void {
        while (self.index < self.source.len) : (self.index += 1) {
            if (self.source[self.index] == '*' and self.matchAhead("*/")) {
                self.index += 2;
                return;
            }
        }
        // Unterminated block comment falls through; parser will see EOF.
    }

    fn scanIdentifier(self: *Lexer, start: usize) LexError!Token {
        self.index += 1;
        while (self.index < self.source.len and isIdentifierBody(self.source[self.index])) {
            self.index += 1;
        }
        const slice = self.source[start..self.index];
        if (keywordFromSlice(slice)) |kw| {
            return Token{
                .kind = TokenKind.keyword,
                .lexeme = slice,
                .span = common.Span.init(start, self.index),
                .keyword = kw,
                .fallback_kind = keywordFallbackKind(kw),
            };
        }
        return Token{
            .kind = TokenKind.identifier,
            .lexeme = slice,
            .span = common.Span.init(start, self.index),
            .keyword = null,
        };
    }

    fn scanString(self: *Lexer, start: usize, delimiter: u8) LexError!Token {
        self.index += 1;
        while (self.index < self.source.len) : (self.index += 1) {
            const ch = self.source[self.index];
            if (ch == delimiter) {
                if (self.index + 1 < self.source.len and self.source[self.index + 1] == delimiter) {
                    self.index += 1; // escaped delimiter via doubling
                    continue;
                }
                self.index += 1;
                return Token{
                    .kind = if (delimiter == '"') TokenKind.quoted_identifier else TokenKind.string,
                    .lexeme = self.source[start..self.index],
                    .span = common.Span.init(start, self.index),
                    .keyword = null,
                };
            }
        }
        return LexError.UnterminatedString;
    }

    fn scanNumber(self: *Lexer, start: usize) LexError!Token {
        while (self.index < self.source.len and isDigit(self.source[self.index])) {
            self.index += 1;
        }
        if (looksLikeTimestamp(self.source, self.index)) {
            return self.scanTimestamp(start);
        }
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            while (self.index < self.source.len and isDigit(self.source[self.index])) {
                self.index += 1;
            }
        }
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            const exp_start = self.index;
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }
            if (!self.scanDigits()) {
                self.index = exp_start;
            }
        }
        if (matchDurationUnit(self.source[self.index..])) |unit_len| {
            self.index += unit_len;
            const duration_slice = self.source[start..self.index];
            return Token{
                .kind = TokenKind.duration,
                .lexeme = duration_slice,
                .span = common.Span.init(start, self.index),
                .literal_class = .duration,
            };
        }
        const slice = self.source[start..self.index];
        return Token{
            .kind = TokenKind.number,
            .lexeme = slice,
            .span = common.Span.init(start, self.index),
            .keyword = null,
        };
    }

    fn scanTimestamp(self: *Lexer, start: usize) LexError!Token {
        while (self.index < self.source.len and isTimestampBody(self.source[self.index])) {
            self.index += 1;
        }
        return Token{
            .kind = TokenKind.timestamp,
            .lexeme = self.source[start..self.index],
            .span = common.Span.init(start, self.index),
            .literal_class = .timestamp,
        };
    }

    fn scanParameter(self: *Lexer, start: usize, kind: ParameterKind) LexError!Token {
        self.index += 1;
        const payload_start = self.index;
        while (self.index < self.source.len and isParameterBody(self.source[self.index])) {
            self.index += 1;
        }
        const payload = self.source[payload_start..self.index];
        if (payload.len == 0) return LexError.InvalidLiteral;

        var parameter = Parameter{ .kind = kind };
        switch (kind) {
            .positional => parameter.index = std.fmt.parseUnsigned(u32, payload, 10) catch return LexError.InvalidLiteral,
            .named => parameter.name = payload,
        }

        return Token{
            .kind = TokenKind.parameter,
            .lexeme = self.source[start..self.index],
            .span = common.Span.init(start, self.index),
            .parameter = parameter,
        };
    }

    fn scanDigits(self: *Lexer) bool {
        const start = self.index;
        while (self.index < self.source.len and isDigit(self.source[self.index])) {
            self.index += 1;
        }
        return self.index > start;
    }

    fn makeSimpleToken(self: *Lexer, kind: TokenKind, start: usize, width: usize) Token {
        self.index = start + width;
        return Token{
            .kind = kind,
            .lexeme = self.source[start..self.index],
            .span = common.Span.init(start, self.index),
            .keyword = null,
        };
    }

    fn matchChar(self: *Lexer, expected: u8) bool {
        if (self.index + 1 >= self.source.len) return false;
        if (self.source[self.index + 1] == expected) {
            self.index += 2;
            return true;
        }
        return false;
    }

    fn matchAhead(self: *Lexer, probe: []const u8) bool {
        if (self.index + probe.len > self.source.len) return false;
        const slice = self.source[self.index .. self.index + probe.len];
        return std.mem.eql(u8, slice, probe);
    }
};

pub fn diagnosticForError(err: LexError, span: ?common.Span) frontend_diagnostics.Diagnostic {
    return switch (err) {
        error.InvalidLiteral => .{
            .code = .invalid_literal,
            .message = "invalid literal",
            .span = span,
            .phase = .lex,
        },
        error.UnterminatedString => .{
            .code = .unexpected_eof,
            .message = "unterminated string literal",
            .span = span,
            .phase = .lex,
        },
    };
}

fn eofToken(index: usize) Token {
    return Token{
        .kind = TokenKind.eof,
        .lexeme = ""[0..0],
        .span = common.Span.init(index, index),
        .keyword = null,
    };
}

fn isIdentifierStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isIdentifierBody(ch: u8) bool {
    return isIdentifierStart(ch) or isDigit(ch);
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

fn isParameterBody(ch: u8) bool {
    return isIdentifierBody(ch);
}

fn isTimestampBody(ch: u8) bool {
    return isDigit(ch) or ch == '-' or ch == ':' or ch == 'T' or ch == 't' or ch == 'Z' or ch == 'z' or ch == '.' or ch == '+';
}

fn looksLikeTimestamp(source: []const u8, index: usize) bool {
    return index + 1 < source.len and source[index] == '-' and isDigit(source[index + 1]);
}

fn matchDurationUnit(rest: []const u8) ?usize {
    const units = [_][]const u8{ "ns", "us", "ms", "s", "m", "h", "d", "w" };
    for (units) |unit| {
        if (rest.len < unit.len) continue;
        if (std.ascii.eqlIgnoreCase(rest[0..unit.len], unit)) return unit.len;
    }
    return null;
}

fn keywordFallbackKind(keyword: Keyword) ?TokenKind {
    return switch (keyword) {
        .tag, .time, .now, .previous, .linear => .identifier,
        else => null,
    };
}

fn keywordFromSlice(slice: []const u8) ?Keyword {
    for (keyword_table) |entry| {
        if (slice.len != entry.name.len) continue;
        if (std.ascii.eqlIgnoreCase(slice, entry.name)) return entry.keyword;
    }
    return null;
}

const keyword_table = [_]struct {
    name: []const u8,
    keyword: Keyword,
}{
    .{ .name = "select", .keyword = .select },
    .{ .name = "from", .keyword = .from },
    .{ .name = "where", .keyword = .where },
    .{ .name = "group", .keyword = .group },
    .{ .name = "by", .keyword = .by },
    .{ .name = "fill", .keyword = .fill },
    .{ .name = "order", .keyword = .order },
    .{ .name = "limit", .keyword = .limit },
    .{ .name = "offset", .keyword = .offset },
    .{ .name = "insert", .keyword = .insert },
    .{ .name = "into", .keyword = .into },
    .{ .name = "values", .keyword = .values },
    .{ .name = "delete", .keyword = .delete },
    .{ .name = "explain", .keyword = .explain },
    .{ .name = "as", .keyword = .as },
    .{ .name = "tag", .keyword = .tag },
    .{ .name = "time", .keyword = .time },
    .{ .name = "now", .keyword = .now },
    .{ .name = "between", .keyword = .between },
    .{ .name = "and", .keyword = .logical_and },
    .{ .name = "or", .keyword = .logical_or },
    .{ .name = "not", .keyword = .logical_not },
    .{ .name = "previous", .keyword = .previous },
    .{ .name = "linear", .keyword = .linear },
    .{ .name = "asc", .keyword = .asc },
    .{ .name = "desc", .keyword = .desc },
    .{ .name = "true", .keyword = .boolean_true },
    .{ .name = "false", .keyword = .boolean_false },
    .{ .name = "null", .keyword = .null_literal },
};

test "lexer emits eof for empty input" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "");
    const token = try lexer.next();
    try std.testing.expectEqual(TokenKind.eof, token.kind);
    try std.testing.expectEqual(@as(usize, 0), token.span.start);
    try std.testing.expectEqual(@as(usize, 0), token.span.end);
}

test "identifier recognised as keyword" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "SELECT");
    const token = try lexer.next();
    try std.testing.expectEqual(TokenKind.keyword, token.kind);
    try std.testing.expect(token.keyword != null);
    try std.testing.expect(token.keyword.? == Keyword.select);
}

test "numbers and strings lex" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "42 'value'");
    var tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.number, tok.kind);
    tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.string, tok.kind);
    try std.testing.expectEqualStrings("'value'", tok.lexeme);
}

test "lexer recognizes parameter, duration, and timestamp tokens" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "$1 :name 5m 2026-03-27T10:15:00Z");
    var tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.parameter, tok.kind);
    try std.testing.expectEqual(@as(u32, 1), tok.parameter.?.index.?);

    tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.parameter, tok.kind);
    try std.testing.expectEqualStrings("name", tok.parameter.?.name.?);

    tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.duration, tok.kind);
    try std.testing.expectEqual(LiteralClass.duration, tok.literal_class);

    tok = try lexer.next();
    try std.testing.expectEqual(TokenKind.timestamp, tok.kind);
    try std.testing.expectEqual(LiteralClass.timestamp, tok.literal_class);
}

test "keyword fallback preserves identifier-like tokens" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "time tag previous linear");
    var tok = try lexer.next();
    try std.testing.expect(tok.canFallbackToIdentifier());
    try std.testing.expect(tok.isIdentifierLike());

    tok = try lexer.next();
    try std.testing.expect(tok.canFallbackToIdentifier());

    tok = try lexer.next();
    try std.testing.expect(tok.canFallbackToIdentifier());

    tok = try lexer.next();
    try std.testing.expect(tok.canFallbackToIdentifier());
}

test "collectAll returns a full token stream" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "select $1");
    const tokens = try lexer.collectAll(alloc);
    defer alloc.free(tokens);

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenKind.keyword, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.parameter, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.eof, tokens[2].kind);
}

test "lexer skips comments" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "-- comment\r\n/* block */ SELECT");
    const token = try lexer.next();
    try std.testing.expectEqual(TokenKind.keyword, token.kind);
    try std.testing.expect(token.keyword != null);
    try std.testing.expect(token.keyword.? == Keyword.select);
}

test "peek does not consume token" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "select from");
    const first_peek = try lexer.peek();
    try std.testing.expectEqual(TokenKind.keyword, first_peek.kind);
    const first = try lexer.next();
    try std.testing.expectEqualStrings(first.lexeme, first_peek.lexeme);
    const second = try lexer.next();
    try std.testing.expectEqual(TokenKind.keyword, second.kind);
    try std.testing.expect(second.keyword != null);
    try std.testing.expect(second.keyword.? == Keyword.from);
}

test "unterminated string returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    var lexer = Lexer.init(alloc, "'broken");
    try std.testing.expectError(LexError.UnterminatedString, lexer.next());
}
