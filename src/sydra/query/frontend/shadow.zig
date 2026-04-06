const std = @import("std");

const ast = @import("../ast.zig");
const diagnostics = @import("diagnostics.zig");
const grammar = @import("grammar.zig");
const lexer = @import("../lexer.zig");
const legacy_parser = @import("../parser.zig");
const parsergen = @import("parsergen.zig");
const stmt_mod = @import("stmt.zig");
const sydraql_core = @import("grammars/sydraql_core.zig");
const sydraql_semantics = @import("sydraql_semantics.zig");

pub const ShadowParseResult = struct {
    allocator: std.mem.Allocator,
    statement: ast.Statement,
    generated_stmt: ?stmt_mod.FrontendStmt = null,
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

pub fn parseSydraqlShadow(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || lexer.LexError || legacy_parser.ParseError || error{ InvalidTrace, InvalidCharacter })!ShadowParseResult {
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
    const generated_stmt = try parseWithGeneratedRuntime(allocator, arena_ptr.allocator(), &diags, tokens, &tables);
    try validateStatementShape(&diags, tokens, statement, generated_stmt);

    return .{
        .allocator = allocator,
        .statement = statement,
        .generated_stmt = generated_stmt,
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
    generated_stmt: ?stmt_mod.FrontendStmt,
) !void {
    if (tokens.len == 0) return;
    const first = tokens[0];
    const expected_tag = if (generated_stmt) |stmt| toLegacyStatementTag(stmt.kind()) else classifyByFirstToken(first);

    if (std.meta.activeTag(statement) != expected_tag) {
        try list.append(.{
            .code = .parser_mismatch,
            .message = "generated-parser shadow classification diverged from handwritten parser",
            .span = first.span,
            .phase = .parse,
        });
        return;
    }

    if (generated_stmt) |stmt| {
        if (!generatedMatchesLegacy(stmt, statement)) {
            try list.append(.{
                .code = .parser_mismatch,
                .message = "generated frontend statement shape diverged from handwritten parser output",
                .span = stmt.span(),
                .phase = .parse,
            });
        }
    }
}

fn parseWithGeneratedRuntime(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    list: *std.array_list.Managed(diagnostics.Diagnostic),
    tokens: []const lexer.Token,
    tables: *const parsergen.ParserTables,
) std.mem.Allocator.Error!?stmt_mod.FrontendStmt {
    const terminal_ids = try collectGeneratedTerminalIds(allocator, tokens, tables);
    if (terminal_ids == null) return null;
    defer allocator.free(terminal_ids.?);

    var generated = try parsergen.GeneratedParser.init(allocator, tables, .{});
    defer generated.deinit();

    var artifact = try generated.parseArtifact(terminal_ids.?);
    errdefer artifact.deinit(allocator);

    if (!artifact.accepted) {
        defer artifact.deinit(allocator);
        try list.append(.{
            .code = .parser_mismatch,
            .message = "generated sydraql parser runtime could not accept the shared token stream",
            .span = failureSpan(tokens, artifact.failure),
            .phase = .parse,
        });
        return null;
    }

    var semantic = sydraql_semantics.buildStmt(allocator, arena, tokens, tables, artifact) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            defer artifact.deinit(allocator);
            try list.append(.{
                .code = .parser_mismatch,
                .message = "generated sydraql semantic replay could not build a frontend statement",
                .span = failureSpan(tokens, null),
                .phase = .parse,
            });
            return null;
        },
    };
    defer semantic.parse.deinit(allocator);
    return semantic.stmt;
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

fn runtimeTerminalNameForToken(token: lexer.Token) []const u8 {
    return switch (token.kind) {
        .identifier, .quoted_identifier => "identifier",
        .number => "number",
        .string => "string",
        .duration => "duration",
        .timestamp => "timestamp",
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
            .boolean_true => "true",
            .boolean_false => "false",
            .null_literal => "null",
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

fn toLegacyStatementTag(kind: stmt_mod.StatementKind) std.meta.Tag(ast.Statement) {
    return switch (kind) {
        .select => .select,
        .insert => .insert,
        .delete => .delete,
        .explain => .explain,
    };
}

fn generatedMatchesLegacy(generated_stmt: stmt_mod.FrontendStmt, legacy_stmt: ast.Statement) bool {
    switch (generated_stmt) {
        .select => |generated_select| {
            if (legacy_stmt != .select) return false;
            const legacy_select = legacy_stmt.select.*;
            return generated_select.projections.len == legacy_select.projections.len and
                (generated_select.selector != null) == (legacy_select.selector != null) and
                (generated_select.predicate != null) == (legacy_select.predicate != null) and
                spansEqual(generated_select.span, legacy_select.span);
        },
        .insert => |generated_insert| {
            if (legacy_stmt != .insert) return false;
            const legacy_insert = legacy_stmt.insert.*;
            return std.mem.eql(u8, generated_insert.target.value, legacy_insert.series.value) and
                spansEqual(generated_insert.span, legacy_insert.span);
        },
        .delete => |generated_delete| {
            if (legacy_stmt != .delete) return false;
            const legacy_delete = legacy_stmt.delete.*;
            return switch (legacy_delete.selector.series) {
                .name => |name| std.mem.eql(u8, generated_delete.target.value, name.value) and spansEqual(generated_delete.span, legacy_delete.span),
                .by_id => false,
            };
        },
        .explain => |generated_explain| {
            if (legacy_stmt != .explain) return false;
            const legacy_explain = legacy_stmt.explain.*;
            return generated_explain.mode == toFrontendExplainMode(legacy_explain.mode) and
                spansEqual(generated_explain.span, legacy_explain.span) and
                generatedMatchesLegacy(generated_explain.target.*, legacy_explain.target.*);
        },
    }
}

fn toFrontendExplainMode(mode: ast.ExplainMode) stmt_mod.ExplainMode {
    return switch (mode) {
        .standard => .standard,
        .bytecode => .bytecode,
        .tables_used => .tables_used,
    };
}

fn spansEqual(lhs: @import("../common.zig").Span, rhs: @import("../common.zig").Span) bool {
    return lhs.start == rhs.start and lhs.end == rhs.end;
}

fn terminalNameForToken(token: lexer.Token) []const u8 {
    return switch (token.kind) {
        .identifier, .quoted_identifier => "identifier",
        .number => "number",
        .string => "string",
        .duration => "duration",
        .timestamp => "timestamp",
        .parameter => "identifier",
        .keyword => switch (token.keyword.?) {
            .select => "select",
            .insert => "insert",
            .delete => "delete",
            .explain => "explain",
            .bytecode => "bytecode",
            .tables_used => "tables_used",
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
            .boolean_true => "true",
            .boolean_false => "false",
            .null_literal => "null",
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
    try std.testing.expect(result.generated_stmt != null);
}

test "shadow sydraql parser covers explain tables-used" {
    const alloc = std.testing.allocator;
    const result = try parseSydraqlShadow(alloc, "explain tables_used select 1");
    defer {
        var owned = result;
        owned.deinit();
    }

    try std.testing.expect(result.statement == .explain);
    try std.testing.expect(!result.hasMismatch());
    try std.testing.expect(result.generated_stmt != null);
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
    try std.testing.expect(result.generated_stmt != null);
    try std.testing.expectEqual(stmt_mod.StatementKind.select, result.generated_stmt.?.kind());
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
