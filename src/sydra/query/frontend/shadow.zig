const std = @import("std");

const ast = @import("../ast.zig");
const diagnostics = @import("diagnostics.zig");
const grammar = @import("grammar.zig");
const lexer = @import("../lexer.zig");
const legacy_parser = @import("../parser.zig");
const parsergen = @import("parsergen.zig");
const sydraql_core = @import("grammars/sydraql_core.zig");

pub const ShadowParseResult = struct {
    allocator: std.mem.Allocator,
    statement: ast.Statement,
    diagnostics: []const diagnostics.Diagnostic,
    emitted: parsergen.EmissionArtifact,
    token_count: usize,
    arena_ptr: *std.heap.ArenaAllocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.diagnostics);
        self.allocator.free(self.emitted.emitted_source);
        self.arena_ptr.deinit();
        self.allocator.destroy(self.arena_ptr);
    }

    pub fn hasMismatch(self: @This()) bool {
        for (self.diagnostics) |diag| {
            if (diag.code == .parser_mismatch) return true;
        }
        return false;
    }
};

pub fn parseSydraqlShadow(allocator: std.mem.Allocator, source: []const u8) !ShadowParseResult {
    var lex = lexer.Lexer.init(allocator, source);
    const tokens = try lex.collectAll(allocator);
    defer allocator.free(tokens);

    var gen = parsergen.ParserGenerator.init(allocator);
    var tables = try gen.buildTables(sydraql_core.spec);
    defer tables.deinit(allocator);
    const emitted = try gen.emit(sydraql_core.spec);
    errdefer allocator.free(emitted.emitted_source);

    var arena_ptr = try allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena_ptr.deinit();
        allocator.destroy(arena_ptr);
    }

    var parser = legacy_parser.Parser.init(arena_ptr.allocator(), source);
    const statement = try parser.parse();

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    errdefer diags.deinit();

    try validateTokens(&diags, tokens, sydraql_core.spec);
    const generated_kind = try parseWithGeneratedRuntime(allocator, &diags, tokens, &tables);
    try validateStatementShape(&diags, tokens, statement, generated_kind);

    return .{
        .allocator = allocator,
        .statement = statement,
        .diagnostics = try diags.toOwnedSlice(),
        .emitted = emitted,
        .token_count = tokens.len,
        .arena_ptr = arena_ptr,
    };
}

fn validateTokens(list: *std.array_list.Managed(diagnostics.Diagnostic), tokens: []const lexer.Token, spec: grammar.GrammarSpec) !void {
    for (tokens) |token| {
        const terminal = terminalNameForToken(token);
        if (terminal.len == 0) {
            try list.append(.{
                .code = .unsupported_feature,
                .message = "token has no generated-parser terminal mapping",
                .span = token.span,
                .phase = .parse,
            });
            continue;
        }
        if (!hasTerminal(spec.tokens, terminal)) {
            try list.append(.{
                .code = .lexer_mismatch,
                .message = "shared lexer emitted a token not covered by sydraql_core grammar",
                .span = token.span,
                .phase = .parse,
            });
        }
    }
}

fn validateStatementShape(
    list: *std.array_list.Managed(diagnostics.Diagnostic),
    tokens: []const lexer.Token,
    statement: ast.Statement,
    generated_kind: ?std.meta.Tag(ast.Statement),
) !void {
    if (tokens.len == 0) return;
    const first = tokens[0];
    const expected_tag = generated_kind orelse classifyByFirstToken(first);

    if (std.meta.activeTag(statement) != expected_tag) {
        try list.append(.{
            .code = .parser_mismatch,
            .message = "generated-parser shadow classification diverged from handwritten parser",
            .span = first.span,
            .phase = .parse,
        });
    }
}

fn parseWithGeneratedRuntime(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(diagnostics.Diagnostic),
    tokens: []const lexer.Token,
    tables: *const parsergen.ParserTables,
) !?std.meta.Tag(ast.Statement) {
    const terminal_ids = try collectGeneratedTerminalIds(allocator, tokens, tables);
    if (terminal_ids == null) return null;
    defer allocator.free(terminal_ids.?);

    var generated = try parsergen.GeneratedParser.init(allocator, tables, .{});
    defer generated.deinit();

    var result = generated.parse(terminal_ids.?) catch |err| switch (err) {
        error.ParseError, error.DisabledRule => {
            const failure = generated.failureInfo();
            try list.append(.{
                .code = .parser_mismatch,
                .message = "generated sydraql parser runtime could not accept the shared token stream",
                .span = failureSpan(tokens, failure),
                .phase = .parse,
            });
            return null;
        },
        else => return err,
    };
    defer result.deinit(allocator);

    if (!result.accepted) return null;
    return generatedStatementKind(tables.*, result.reductions);
}

fn failureSpan(tokens: []const lexer.Token, failure: ?parsergen.FailureInfo) ?@import("../common.zig").Span {
    if (failure) |info| {
        if (info.token_index < tokens.len) return tokens[info.token_index].span;
    }
    return if (tokens.len == 0) null else tokens[0].span;
}

fn collectGeneratedTerminalIds(
    allocator: std.mem.Allocator,
    tokens: []const lexer.Token,
    tables: *const parsergen.ParserTables,
) !?[]u16 {
    var ids = std.array_list.Managed(u16).init(allocator);
    defer ids.deinit();

    for (tokens) |token| {
        const terminal = runtimeTerminalNameForToken(token);
        if (terminal.len == 0) return null;
        const terminal_id = tables.terminalId(terminal) orelse return null;
        try ids.append(terminal_id);
    }

    return try ids.toOwnedSlice();
}

fn generatedStatementKind(
    tables: parsergen.ParserTables,
    reductions: []const u16,
) ?std.meta.Tag(ast.Statement) {
    var idx = reductions.len;
    while (idx > 0) {
        idx -= 1;
        const rule_index = reductions[idx];
        const rule = tables.rules[rule_index];
        if (rule.lhs_nonterminal >= tables.nonterminals.len) continue;
        if (!std.mem.eql(u8, tables.nonterminals[rule.lhs_nonterminal], "stmt")) continue;

        const rhs = tables.rhs_symbols[rule.rhs_start .. rule.rhs_start + rule.rhs_len];
        if (rhs.len == 1 and rhs[0].kind == .nonterminal and rhs[0].index < tables.nonterminals.len) {
            if (std.mem.eql(u8, tables.nonterminals[rhs[0].index], "select_stmt")) return .select;
        }

        if (rhs.len == 0 or rhs[0].kind != .terminal) continue;
        const terminal = tables.terminalName(rhs[0].index);
        if (std.mem.eql(u8, terminal, "insert")) return .insert;
        if (std.mem.eql(u8, terminal, "delete")) return .delete;
        if (std.mem.eql(u8, terminal, "explain")) return .explain;
    }
    return null;
}

fn runtimeTerminalNameForToken(token: lexer.Token) []const u8 {
    return switch (token.kind) {
        .identifier, .quoted_identifier => "identifier",
        .number => "number",
        .string => "string",
        .duration => "number",
        .timestamp => "string",
        .keyword => switch (token.keyword.?) {
            .select => "select",
            .insert => "insert",
            .delete => "delete",
            .explain => "explain",
            .bytecode => "bytecode",
            .from => "from",
            .where => "where",
            .group => "group",
            .by => "by",
            .fill => "fill",
            .order => "order",
            .limit => "limit",
            .offset => "offset",
            .time => "time",
            .tag => "tag",
            else => "",
        },
        .comma => "comma",
        .l_paren => "l_paren",
        .r_paren => "r_paren",
        .eof => "eof",
        else => "",
    };
}

fn classifyByFirstToken(token: lexer.Token) std.meta.Tag(ast.Statement) {
    return switch (token.kind) {
        .keyword => switch (token.keyword.?) {
            .select => .select,
            .insert => .insert,
            .delete => .delete,
            .explain => .explain,
            else => .invalid,
        },
        else => .invalid,
    };
}

fn terminalNameForToken(token: lexer.Token) []const u8 {
    return switch (token.kind) {
        .identifier, .quoted_identifier => "identifier",
        .number => "number",
        .string => "string",
        .duration => "number",
        .timestamp => "string",
        .parameter => "identifier",
        .keyword => switch (token.keyword.?) {
            .select => "select",
            .insert => "insert",
            .delete => "delete",
            .explain => "explain",
            .bytecode => "bytecode",
            .from => "from",
            .where => "where",
            .group => "group",
            .by => "by",
            .fill => "fill",
            .order => "order",
            .limit => "limit",
            .offset => "offset",
            .time => "time",
            .tag => "tag",
            else => "identifier",
        },
        .comma => "comma",
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

test "shadow sydraql parser stays aligned with handwritten parser for select" {
    const alloc = std.testing.allocator;
    const result = try parseSydraqlShadow(alloc, "select time, value from weather.room1 where time >= 10 order by time limit 5");
    defer {
        var owned = result;
        owned.deinit();
    }

    try std.testing.expect(result.statement == .select);
    try std.testing.expect(!result.hasMismatch());
    try std.testing.expect(result.token_count >= 10);
}

test "shadow sydraql parser tracks insert and delete statement kinds" {
    const alloc = std.testing.allocator;

    const insert_result = try parseSydraqlShadow(alloc, "insert into metrics(time, value) values(1, 2)");
    defer {
        var owned = insert_result;
        owned.deinit();
    }
    try std.testing.expect(insert_result.statement == .insert);
    try std.testing.expect(!insert_result.hasMismatch());

    const delete_result = try parseSydraqlShadow(alloc, "delete from metrics where time >= 1");
    defer {
        var owned = delete_result;
        owned.deinit();
    }
    try std.testing.expect(delete_result.statement == .delete);
    try std.testing.expect(!delete_result.hasMismatch());
}

test "shadow sydraql parser covers explain bytecode" {
    const alloc = std.testing.allocator;
    const result = try parseSydraqlShadow(alloc, "explain bytecode select 1");
    defer {
        var owned = result;
        owned.deinit();
    }

    try std.testing.expect(result.statement == .explain);
    try std.testing.expect(!result.hasMismatch());
}

test "shadow sydraql parser uses generated runtime on covered selects" {
    const alloc = std.testing.allocator;
    const result = try parseSydraqlShadow(alloc, "select 1");
    defer {
        var owned = result;
        owned.deinit();
    }

    try std.testing.expect(result.statement == .select);
    try std.testing.expect(!result.hasMismatch());
}

test "shadow sydraql parser matches fixture cases" {
    const alloc = std.testing.allocator;
    const contents = @embedFile("sydraql_shadow_cases.tsv");
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0 or line[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, line, '|');
        const kind_text = fields.next() orelse return error.InvalidCharacter;
        const mismatch_text = fields.next() orelse return error.InvalidCharacter;
        const query = fields.next() orelse return error.InvalidCharacter;

        const result = try parseSydraqlShadow(alloc, query);
        defer {
            var owned = result;
            owned.deinit();
        }

        const expected_tag = std.meta.stringToEnum(std.meta.Tag(ast.Statement), kind_text) orelse return error.InvalidCharacter;
        const expected_mismatch = std.mem.eql(u8, mismatch_text, "true");
        try std.testing.expectEqual(expected_tag, std.meta.activeTag(result.statement));
        try std.testing.expectEqual(expected_mismatch, result.hasMismatch());
    }
}
