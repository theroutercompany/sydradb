const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const grammar = @import("grammar.zig");
const lexer = @import("../lexer.zig");
const sql_core_ts = @import("grammars/sql_core_ts.zig");

pub const StatementKind = enum {
    select,
    insert,
    delete,
    explain,
    unknown,
};

pub const SkeletonResult = struct {
    kind: StatementKind,
    diagnostics: []const diagnostics.Diagnostic,
    token_count: usize,
};

pub fn parseSqlCoreSkeleton(allocator: std.mem.Allocator, source: []const u8) !SkeletonResult {
    var lex = lexer.Lexer.init(allocator, source);
    const tokens = try lex.collectAll(allocator);
    defer allocator.free(tokens);

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    errdefer diags.deinit();

    for (tokens) |token| {
        const terminal = terminalNameForToken(token);
        if (terminal.len == 0 or !hasTerminal(sql_core_ts.spec.tokens, terminal)) {
            try diags.append(.{
                .code = .lexer_mismatch,
                .message = "shared lexer emitted a token outside sql_core_ts grammar coverage",
                .span = token.span,
                .phase = .parse,
            });
        }
    }

    return .{
        .kind = classify(tokens),
        .diagnostics = try diags.toOwnedSlice(),
        .token_count = tokens.len,
    };
}

fn classify(tokens: []const lexer.Token) StatementKind {
    if (tokens.len == 0) return .unknown;
    const first = tokens[0];
    if (first.kind != .keyword or first.keyword == null) return .unknown;
    return switch (first.keyword.?) {
        .select => .select,
        .insert => .insert,
        .delete => .delete,
        .explain => .explain,
        else => .unknown,
    };
}

fn terminalNameForToken(token: lexer.Token) []const u8 {
    return switch (token.kind) {
        .identifier, .quoted_identifier => "identifier",
        .number, .duration => "number",
        .string, .timestamp => "string",
        .parameter => "parameter",
        .keyword => switch (token.keyword.?) {
            .select => "select",
            .insert => "insert",
            .delete => "delete",
            .explain => "explain",
            .bytecode => "bytecode",
            .into => "into",
            .from => "from",
            .where => "where",
            .group => "group",
            .by => "by",
            .order => "order",
            .limit => "limit",
            .offset => "offset",
            .values => "values",
            .as => "as",
            .asc => "asc",
            .desc => "desc",
            else => "identifier",
        },
        .comma => "comma",
        .equal => "equal",
        .bang_equal => "bang_equal",
        .less => "less",
        .less_equal => "less_equal",
        .greater => "greater",
        .greater_equal => "greater_equal",
        .star => "star",
        .l_paren => "l_paren",
        .r_paren => "r_paren",
        .eof => "eof",
        else => "",
    };
}

fn hasTerminal(tokens: []const grammar.TokenSpec, name: []const u8) bool {
    for (tokens) |token| {
        if (std.mem.eql(u8, token.name, name)) return true;
    }
    return false;
}

test "sql core parser skeleton matches golden cases" {
    const alloc = std.testing.allocator;
    const contents = @embedFile("sql_core_parser_cases.tsv");
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '|');
        const kind_text = fields.next() orelse return error.InvalidCharacter;
        const sql = fields.next() orelse return error.InvalidCharacter;

        const result = try parseSqlCoreSkeleton(alloc, sql);
        defer alloc.free(result.diagnostics);

        const expected = std.meta.stringToEnum(StatementKind, kind_text) orelse return error.InvalidCharacter;
        try std.testing.expectEqual(expected, result.kind);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expect(result.token_count >= 2);
    }
}
