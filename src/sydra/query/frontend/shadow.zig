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
    emitted: parsergen.ParseArtifact,
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
    try validateStatementShape(&diags, tokens, statement);

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

fn validateStatementShape(list: *std.array_list.Managed(diagnostics.Diagnostic), tokens: []const lexer.Token, statement: ast.Statement) !void {
    if (tokens.len == 0) return;
    const first = tokens[0];
    const expected_tag = switch (first.kind) {
        .keyword => switch (first.keyword.?) {
            .select => std.meta.Tag(ast.Statement).select,
            .insert => std.meta.Tag(ast.Statement).insert,
            .delete => std.meta.Tag(ast.Statement).delete,
            .explain => std.meta.Tag(ast.Statement).explain,
            else => std.meta.Tag(ast.Statement).invalid,
        },
        else => std.meta.Tag(ast.Statement).invalid,
    };

    if (std.meta.activeTag(statement) != expected_tag) {
        try list.append(.{
            .code = .parser_mismatch,
            .message = "generated-parser shadow classification diverged from handwritten parser",
            .span = first.span,
            .phase = .parse,
        });
    }
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
