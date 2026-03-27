const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const grammar = @import("grammar.zig");
const lexer = @import("../lexer.zig");
const parsergen = @import("parsergen.zig");
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
    used_generated_runtime: bool,
};

pub fn parseSqlCoreSkeleton(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || lexer.LexError)!SkeletonResult {
    var lex = lexer.Lexer.init(allocator, source);
    const tokens = try lex.collectAll(allocator);
    defer allocator.free(tokens);

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    errdefer diags.deinit();

    var gen = parsergen.ParserGenerator.init(allocator);
    var tables = gen.buildTables(sql_core_ts.spec) catch unreachable;
    defer tables.deinit(allocator);

    const terminal_ids = try collectGeneratedTerminalIds(allocator, &diags, tokens, &tables);
    const used_generated_runtime = terminal_ids != null;
    defer if (terminal_ids) |ids| allocator.free(ids);

    var kind = classify(tokens);
    if (terminal_ids) |ids| {
        var generated = try parsergen.GeneratedParser.init(allocator, &tables, .{});
        defer generated.deinit();

        var result = generated.parse(ids) catch |err| switch (err) {
            error.ParseError, error.DisabledRule => {
                try diags.append(.{
                    .code = .unexpected_token,
                    .message = "generated sql_core_ts parser could not accept the covered token stream",
                    .span = firstMeaningfulSpan(tokens),
                    .phase = .parse,
                });
                return .{
                    .kind = kind,
                    .diagnostics = try diags.toOwnedSlice(),
                    .token_count = tokens.len,
                    .used_generated_runtime = true,
                };
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer result.deinit(allocator);

        if (generatedStatementKind(tables, result.reductions)) |generated_kind| {
            kind = generated_kind;
        }
    }

    return .{
        .kind = kind,
        .diagnostics = try diags.toOwnedSlice(),
        .token_count = tokens.len,
        .used_generated_runtime = used_generated_runtime,
    };
}

fn collectGeneratedTerminalIds(
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    tokens: []const lexer.Token,
    tables: *const parsergen.ParserTables,
) !?[]u16 {
    var ids = std.array_list.Managed(u16).init(allocator);
    defer ids.deinit();

    var fully_covered = true;
    for (tokens) |token| {
        const terminal = terminalNameForToken(token);
        if (terminal.len == 0) {
            fully_covered = false;
            try diags.append(.{
                .code = .lexer_mismatch,
                .message = "shared lexer emitted a token outside sql_core_ts grammar coverage",
                .span = token.span,
                .phase = .parse,
            });
            continue;
        }

        const terminal_id = tables.terminalId(terminal) orelse {
            fully_covered = false;
            try diags.append(.{
                .code = .lexer_mismatch,
                .message = "shared lexer emitted a token outside generated sql_core_ts terminals",
                .span = token.span,
                .phase = .parse,
            });
            continue;
        };
        try ids.append(terminal_id);
    }

    if (!fully_covered) return null;
    return try ids.toOwnedSlice();
}

fn generatedStatementKind(
    tables: parsergen.ParserTables,
    reductions: []const u16,
) ?StatementKind {
    var idx = reductions.len;
    while (idx > 0) {
        idx -= 1;
        const rule_index = reductions[idx];
        const rule = tables.rules[rule_index];
        if (rule.lhs_nonterminal >= tables.nonterminals.len) continue;
        if (!std.mem.eql(u8, tables.nonterminals[rule.lhs_nonterminal], "stmt")) continue;

        const rhs = tables.rhs_symbols[rule.rhs_start .. rule.rhs_start + rule.rhs_len];
        if (rhs.len == 1 and rhs[0].kind == .nonterminal and rhs[0].index < tables.nonterminals.len) {
            const child = tables.nonterminals[rhs[0].index];
            if (std.mem.eql(u8, child, "select_stmt")) return .select;
            if (std.mem.eql(u8, child, "insert_stmt")) return .insert;
            if (std.mem.eql(u8, child, "delete_stmt")) return .delete;
        }

        if (rhs.len == 0 or rhs[0].kind != .terminal) continue;
        const terminal = tables.terminalName(rhs[0].index);
        if (std.mem.eql(u8, terminal, "explain")) return .explain;
    }
    return null;
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

fn firstMeaningfulSpan(tokens: []const lexer.Token) ?@import("../common.zig").Span {
    for (tokens) |token| {
        if (token.kind != .eof) return token.span;
    }
    return if (tokens.len == 0) null else tokens[0].span;
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
            .time => "identifier",
            .tag => "identifier",
            else => "",
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
        try std.testing.expect(result.used_generated_runtime);
        try std.testing.expect(result.token_count >= 2);
    }
}

test "sql core parser skeleton reports grammar coverage gaps" {
    const alloc = std.testing.allocator;
    const result = try parseSqlCoreSkeleton(alloc, "select value from metrics where value =~ 'hot'");
    defer alloc.free(result.diagnostics);

    try std.testing.expectEqual(StatementKind.select, result.kind);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.lexer_mismatch, result.diagnostics[0].code);
    try std.testing.expect(!result.used_generated_runtime);
}

test "sql core parser skeleton reports parse errors for covered invalid syntax" {
    const alloc = std.testing.allocator;
    const result = try parseSqlCoreSkeleton(alloc, "select from metrics");
    defer alloc.free(result.diagnostics);

    try std.testing.expectEqual(StatementKind.select, result.kind);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.unexpected_token, result.diagnostics[0].code);
    try std.testing.expect(result.used_generated_runtime);
}
