const std = @import("std");
const grammar = @import("grammar.zig");

pub const SymbolKind = enum {
    terminal,
    nonterminal,
};

pub const SymbolRef = struct {
    kind: SymbolKind,
    index: u16,
};

pub const RuleTable = struct {
    lhs_nonterminal: u16,
    rhs_start: u32,
    rhs_len: u16,
    action: ?[]const u8,
    condition: ?[]const u8,
    destructor: ?[]const u8,
};

pub const Item = struct {
    rule_index: u16,
    dot: u16,
};

pub const StateTable = struct {
    item_start: u32,
    item_len: u16,
    has_accept_item: bool,
};

pub const ParseAction = union(enum) {
    shift: u16,
    reduce: u16,
    accept,
};

pub const ActionEntry = struct {
    state: u16,
    terminal: u16,
    action: ParseAction,
};

pub const GotoEntry = struct {
    state: u16,
    nonterminal: u16,
    next_state: u16,
};

pub const ParserTables = struct {
    grammar_name: []const u8,
    parser_name: []const u8,
    start_symbol: []const u8,
    terminals: []const grammar.TokenSpec,
    nonterminals: []const []const u8,
    rules: []RuleTable,
    rhs_symbols: []SymbolRef,
    states: []StateTable,
    items: []Item,
    action_entries: []ActionEntry,
    goto_entries: []GotoEntry,
    conflict_count: usize,
    end_terminal: u16,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.rules);
        allocator.free(self.rhs_symbols);
        allocator.free(self.states);
        allocator.free(self.items);
        allocator.free(self.action_entries);
        allocator.free(self.goto_entries);
    }

    pub fn terminalId(self: @This(), name: []const u8) ?u16 {
        for (self.terminals, 0..) |token, idx| {
            if (std.mem.eql(u8, token.name, name)) return @intCast(idx);
        }
        return null;
    }

    pub fn terminalName(self: @This(), terminal_id: u16) []const u8 {
        if (terminal_id == self.end_terminal) return "$end";
        return self.terminals[terminal_id].name;
    }

    pub fn fallbackForTerminal(self: @This(), terminal_id: u16) ?u16 {
        if (terminal_id >= self.terminals.len) return null;
        const fallback_name = self.terminals[terminal_id].fallback orelse return null;
        return self.terminalId(fallback_name);
    }

    pub fn actionFor(self: @This(), state: u16, terminal: u16) ?ParseAction {
        for (self.action_entries) |entry| {
            if (entry.state == state and entry.terminal == terminal) return entry.action;
        }
        return null;
    }

    pub fn gotoFor(self: @This(), state: u16, nonterminal: u16) ?u16 {
        for (self.goto_entries) |entry| {
            if (entry.state == state and entry.nonterminal == nonterminal) return entry.next_state;
        }
        return null;
    }

    fn ruleRhs(self: @This(), rule_index: u16) []const SymbolRef {
        const rule = self.rules[rule_index];
        return self.rhs_symbols[rule.rhs_start .. rule.rhs_start + rule.rhs_len];
    }
};

pub const CoverageEvent = union(enum) {
    shift: u16,
    reduce: u16,
    accept,
    fallback: struct {
        from: u16,
        to: u16,
    },
};

pub const RuntimeHooks = struct {
    context: ?*anyopaque = null,
    rule_enabled: ?*const fn (?*anyopaque, usize, ?[]const u8) bool = null,
    coverage: ?*const fn (?*anyopaque, u16, CoverageEvent) void = null,
};

pub const ParseResult = struct {
    accepted: bool,
    reductions: []u16,
    fallback_count: usize,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.reductions);
    }
};

pub const ParseRuntimeError = std.mem.Allocator.Error || error{
    ParseError,
    DisabledRule,
};

pub const FailureReason = enum {
    unexpected_token,
    disabled_rule,
};

pub const FailureInfo = struct {
    reason: FailureReason,
    token_index: usize,
    state: u16,
    lookahead_terminal: u16,
    rule_index: ?u16 = null,
};

pub const GeneratedParser = struct {
    allocator: std.mem.Allocator,
    tables: *const ParserTables,
    hooks: RuntimeHooks,
    stack: std.array_list.Managed(u16),
    reductions: std.array_list.Managed(u16),
    fallback_count: usize,
    last_failure: ?FailureInfo,

    pub fn init(allocator: std.mem.Allocator, tables: *const ParserTables, hooks: RuntimeHooks) !GeneratedParser {
        var parser = GeneratedParser{
            .allocator = allocator,
            .tables = tables,
            .hooks = hooks,
            .stack = std.array_list.Managed(u16).init(allocator),
            .reductions = std.array_list.Managed(u16).init(allocator),
            .fallback_count = 0,
            .last_failure = null,
        };
        errdefer {
            parser.stack.deinit();
            parser.reductions.deinit();
        }
        try parser.stack.append(0);
        return parser;
    }

    pub fn deinit(self: *@This()) void {
        self.stack.deinit();
        self.reductions.deinit();
    }

    pub fn reset(self: *@This()) !void {
        self.stack.clearRetainingCapacity();
        self.reductions.clearRetainingCapacity();
        self.fallback_count = 0;
        self.last_failure = null;
        try self.stack.append(0);
    }

    pub fn failureInfo(self: @This()) ?FailureInfo {
        return self.last_failure;
    }

    pub fn parse(self: *@This(), terminals: []const u16) ParseRuntimeError!ParseResult {
        try self.reset();

        var cursor: usize = 0;
        while (true) {
            const state = self.stack.items[self.stack.items.len - 1];
            const lookahead = if (cursor < terminals.len) terminals[cursor] else self.tables.end_terminal;
            var action = self.tables.actionFor(state, lookahead);
            if (action == null and cursor < terminals.len) {
                if (self.tables.fallbackForTerminal(lookahead)) |fallback_terminal| {
                    if (self.tables.actionFor(state, fallback_terminal)) |fallback_action| {
                        self.fallback_count += 1;
                        self.emitCoverage(state, .{ .fallback = .{
                            .from = lookahead,
                            .to = fallback_terminal,
                        } });
                        action = fallback_action;
                    }
                }
            }

            switch (action orelse {
                self.last_failure = .{
                    .reason = .unexpected_token,
                    .token_index = cursor,
                    .state = state,
                    .lookahead_terminal = lookahead,
                };
                return error.ParseError;
            }) {
                .shift => |next_state| {
                    if (cursor >= terminals.len) return error.ParseError;
                    try self.stack.append(next_state);
                    cursor += 1;
                    self.emitCoverage(state, .{ .shift = next_state });
                },
                .reduce => |rule_index| {
                    if (!self.ruleEnabled(rule_index)) {
                        self.last_failure = .{
                            .reason = .disabled_rule,
                            .token_index = cursor,
                            .state = state,
                            .lookahead_terminal = lookahead,
                            .rule_index = rule_index,
                        };
                        return error.DisabledRule;
                    }
                    const rule = self.tables.rules[rule_index];
                    if (self.stack.items.len <= rule.rhs_len) return error.ParseError;
                    self.stack.items.len -= rule.rhs_len;

                    const parent_state = self.stack.items[self.stack.items.len - 1];
                    const next_state = self.tables.gotoFor(parent_state, rule.lhs_nonterminal) orelse return error.ParseError;
                    try self.stack.append(next_state);
                    try self.reductions.append(rule_index);
                    self.emitCoverage(parent_state, .{ .reduce = rule_index });
                },
                .accept => {
                    self.emitCoverage(state, .accept);
                    return .{
                        .accepted = true,
                        .reductions = try self.allocator.dupe(u16, self.reductions.items),
                        .fallback_count = self.fallback_count,
                    };
                },
            }
        }
    }

    fn ruleEnabled(self: @This(), rule_index: u16) bool {
        const callback = self.hooks.rule_enabled orelse return true;
        return callback(self.hooks.context, rule_index, self.tables.rules[rule_index].condition);
    }

    fn emitCoverage(self: @This(), state: u16, event: CoverageEvent) void {
        const callback = self.hooks.coverage orelse return;
        callback(self.hooks.context, state, event);
    }
};

pub const ParseArtifact = struct {
    grammar_name: []const u8,
    parser_name: []const u8,
    emitted_source: []u8,
    state_count_hint: usize,
    conflict_count_hint: usize,
    fallback_count: usize,
};

pub const ParserGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ParserGenerator {
        return .{ .allocator = allocator };
    }

    pub fn buildTables(self: *ParserGenerator, spec: grammar.GrammarSpec) !ParserTables {
        var terminal_map = std.StringHashMap(u16).init(self.allocator);
        defer terminal_map.deinit();
        for (spec.tokens, 0..) |token, idx| {
            try terminal_map.put(token.name, @intCast(idx));
        }

        var nonterminal_map = std.StringHashMap(u16).init(self.allocator);
        defer nonterminal_map.deinit();
        for (spec.nonterminals, 0..) |symbol, idx| {
            try nonterminal_map.put(symbol, @intCast(idx));
        }

        const start_nonterminal = nonterminal_map.get(spec.start_symbol) orelse return error.InvalidCharacter;
        const augmented_nonterminal: u16 = @intCast(spec.nonterminals.len);
        const total_nonterminals = spec.nonterminals.len + 1;
        const end_terminal: u16 = @intCast(spec.tokens.len);
        const total_terminals = spec.tokens.len + 1;

        var rhs_symbols = std.array_list.Managed(SymbolRef).init(self.allocator);
        errdefer rhs_symbols.deinit();
        var rules = std.array_list.Managed(RuleTable).init(self.allocator);
        errdefer rules.deinit();

        try rhs_symbols.append(.{ .kind = .nonterminal, .index = start_nonterminal });
        try rules.append(.{
            .lhs_nonterminal = augmented_nonterminal,
            .rhs_start = 0,
            .rhs_len = 1,
            .action = null,
            .condition = null,
            .destructor = null,
        });

        for (spec.rules) |rule| {
            const rhs_start: u32 = @intCast(rhs_symbols.items.len);
            for (rule.rhs) |symbol_name| {
                if (terminal_map.get(symbol_name)) |terminal_id| {
                    try rhs_symbols.append(.{ .kind = .terminal, .index = terminal_id });
                } else if (nonterminal_map.get(symbol_name)) |nonterminal_id| {
                    try rhs_symbols.append(.{ .kind = .nonterminal, .index = nonterminal_id });
                } else {
                    return error.InvalidCharacter;
                }
            }
            try rules.append(.{
                .lhs_nonterminal = nonterminal_map.get(rule.lhs) orelse return error.InvalidCharacter,
                .rhs_start = rhs_start,
                .rhs_len = @intCast(rule.rhs.len),
                .action = rule.action,
                .condition = rule.condition,
                .destructor = rule.destructor,
            });
        }

        const nullable = try computeNullable(self.allocator, total_nonterminals, rules.items, rhs_symbols.items);
        defer self.allocator.free(nullable);

        const first = try computeFirst(self.allocator, total_nonterminals, total_terminals, rules.items, rhs_symbols.items, nullable);
        defer self.allocator.free(first);

        const follow = try computeFollow(
            self.allocator,
            total_nonterminals,
            total_terminals,
            rules.items,
            rhs_symbols.items,
            nullable,
            first,
            start_nonterminal,
            end_terminal,
        );
        defer self.allocator.free(follow);

        var automaton = try buildAutomaton(self.allocator, rules.items, rhs_symbols.items, follow, total_terminals);
        errdefer automaton.deinit(self.allocator);

        return .{
            .grammar_name = spec.name,
            .parser_name = spec.parser_name,
            .start_symbol = spec.start_symbol,
            .terminals = spec.tokens,
            .nonterminals = spec.nonterminals,
            .rules = try rules.toOwnedSlice(),
            .rhs_symbols = try rhs_symbols.toOwnedSlice(),
            .states = automaton.states,
            .items = automaton.items,
            .action_entries = automaton.action_entries,
            .goto_entries = automaton.goto_entries,
            .conflict_count = automaton.conflict_count,
            .end_terminal = end_terminal,
        };
    }

    pub fn emit(self: *ParserGenerator, spec: grammar.GrammarSpec) !ParseArtifact {
        var tables = try self.buildTables(spec);
        defer tables.deinit(self.allocator);

        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();

        const writer = out.writer();
        try writer.print("// generated by sydra parsergen for {s}\n", .{spec.name});
        try writer.writeAll("const std = @import(\"std\");\n");
        try writer.writeAll("pub const ParserMetadata = struct {\n");
        try writer.writeAll("    pub const grammar_name = ");
        try writeQuoted(writer, spec.name);
        try writer.writeAll(";\n");
        try writer.writeAll("    pub const parser_name = ");
        try writeQuoted(writer, spec.parser_name);
        try writer.writeAll(";\n");
        try writer.writeAll("    pub const start_symbol = ");
        try writeQuoted(writer, spec.start_symbol);
        try writer.writeAll(";\n");
        try writer.print("    pub const state_count = {d};\n", .{tables.states.len});
        try writer.print("    pub const conflict_count = {d};\n", .{tables.conflict_count});
        try writer.print("    pub const action_count = {d};\n", .{tables.action_entries.len});
        try writer.print("    pub const goto_count = {d};\n", .{tables.goto_entries.len});
        try writer.writeAll("};\n\n");

        try writer.writeAll("pub const tokens = [_][]const u8{\n");
        var fallback_count: usize = 0;
        for (spec.tokens) |token| {
            try writer.writeAll("    ");
            try writeQuoted(writer, token.name);
            try writer.writeAll(",\n");
            if (token.fallback != null) fallback_count += 1;
        }
        try writer.writeAll("};\n\n");

        try writer.writeAll("pub const fallbacks = [_]struct { token: []const u8, fallback: []const u8 }{\n");
        for (spec.tokens) |token| {
            if (token.fallback) |fallback| {
                try writer.writeAll("    .{ .token = ");
                try writeQuoted(writer, token.name);
                try writer.writeAll(", .fallback = ");
                try writeQuoted(writer, fallback);
                try writer.writeAll(" },\n");
            }
        }
        try writer.writeAll("};\n\n");

        try writer.writeAll("pub const nonterminals = [_][]const u8{\n");
        for (spec.nonterminals) |symbol| {
            try writer.writeAll("    ");
            try writeQuoted(writer, symbol);
            try writer.writeAll(",\n");
        }
        try writer.writeAll("};\n\n");

        try writer.writeAll("pub const rules = [_]struct { lhs: []const u8, rhs_len: usize, conditional: bool, has_destructor: bool }{\n");
        for (spec.rules) |rule| {
            try writer.writeAll("    .{ .lhs = ");
            try writeQuoted(writer, rule.lhs);
            try writer.print(", .rhs_len = {d}, .conditional = {}, .has_destructor = {} }},\n", .{
                rule.rhs.len,
                rule.condition != null,
                rule.destructor != null,
            });
        }
        try writer.writeAll("};\n");

        if (spec.coverage_hook_name) |hook| {
            try writer.writeAll("\npub const coverage_hook_name = ");
            try writeQuoted(writer, hook);
            try writer.writeAll(";\n");
        }

        return .{
            .grammar_name = spec.name,
            .parser_name = spec.parser_name,
            .emitted_source = try out.toOwnedSlice(),
            .state_count_hint = tables.states.len,
            .conflict_count_hint = tables.conflict_count,
            .fallback_count = fallback_count,
        };
    }
};

const Transition = struct {
    symbol: SymbolRef,
    next_state: u16,
};

const StateBuilder = struct {
    items: []Item,
    transitions: std.array_list.Managed(Transition),
    has_accept_item: bool,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.transitions.deinit();
    }
};

const AutomatonBuild = struct {
    states: []StateTable,
    items: []Item,
    action_entries: []ActionEntry,
    goto_entries: []GotoEntry,
    conflict_count: usize,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.states);
        allocator.free(self.items);
        allocator.free(self.action_entries);
        allocator.free(self.goto_entries);
    }
};

fn buildAutomaton(
    allocator: std.mem.Allocator,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
    follow: []const bool,
    total_terminals: usize,
) !AutomatonBuild {
    var states = std.array_list.Managed(StateBuilder).init(allocator);
    defer {
        for (states.items) |*state| state.deinit(allocator);
        states.deinit();
    }

    var seed = std.array_list.Managed(Item).init(allocator);
    defer seed.deinit();
    try seed.append(.{ .rule_index = 0, .dot = 0 });
    const start_items = try closureItems(allocator, rules, rhs_symbols, seed.items);
    errdefer allocator.free(start_items);
    try states.append(.{
        .items = start_items,
        .transitions = std.array_list.Managed(Transition).init(allocator),
        .has_accept_item = stateHasAcceptItem(rules, start_items),
    });

    var state_index: usize = 0;
    while (state_index < states.items.len) : (state_index += 1) {
        var symbols = std.array_list.Managed(SymbolRef).init(allocator);
        defer symbols.deinit();

        for (states.items[state_index].items) |item| {
            const rhs = ruleRhs(rules, rhs_symbols, item.rule_index);
            if (item.dot >= rhs.len) continue;
            try appendUniqueSymbol(&symbols, rhs[item.dot]);
        }

        for (symbols.items) |symbol| {
            const moved = try gotoItems(allocator, rules, rhs_symbols, states.items[state_index].items, symbol);
            defer allocator.free(moved);
            if (moved.len == 0) continue;

            const next_state = try findOrAppendState(allocator, &states, moved, rules);
            try states.items[state_index].transitions.append(.{
                .symbol = symbol,
                .next_state = next_state,
            });
        }
    }

    var actions = std.array_list.Managed(ActionEntry).init(allocator);
    errdefer actions.deinit();
    var gotos = std.array_list.Managed(GotoEntry).init(allocator);
    errdefer gotos.deinit();
    var conflict_count: usize = 0;

    for (states.items, 0..) |state, idx| {
        for (state.transitions.items) |transition| {
            if (transition.symbol.kind == .terminal) {
                try mergeAction(&actions, @intCast(idx), transition.symbol.index, .{ .shift = transition.next_state }, &conflict_count);
            } else {
                try gotos.append(.{
                    .state = @intCast(idx),
                    .nonterminal = transition.symbol.index,
                    .next_state = transition.next_state,
                });
            }
        }

        for (state.items) |item| {
            const rhs = ruleRhs(rules, rhs_symbols, item.rule_index);
            if (item.dot != rhs.len) continue;

            if (item.rule_index == 0) {
                try mergeAction(&actions, @intCast(idx), @intCast(total_terminals - 1), .accept, &conflict_count);
                continue;
            }

            const rule = rules[item.rule_index];
            var terminal_index: usize = 0;
            while (terminal_index < total_terminals) : (terminal_index += 1) {
                if (!matrixHas(follow, total_terminals, rule.lhs_nonterminal, @intCast(terminal_index))) continue;
                try mergeAction(&actions, @intCast(idx), @intCast(terminal_index), .{ .reduce = item.rule_index }, &conflict_count);
            }
        }
    }

    var flat_states = try allocator.alloc(StateTable, states.items.len);
    errdefer allocator.free(flat_states);

    var item_storage = std.array_list.Managed(Item).init(allocator);
    errdefer item_storage.deinit();
    for (states.items, 0..) |state, idx| {
        flat_states[idx] = .{
            .item_start = @intCast(item_storage.items.len),
            .item_len = @intCast(state.items.len),
            .has_accept_item = state.has_accept_item,
        };
        try item_storage.appendSlice(state.items);
    }

    return .{
        .states = flat_states,
        .items = try item_storage.toOwnedSlice(),
        .action_entries = try actions.toOwnedSlice(),
        .goto_entries = try gotos.toOwnedSlice(),
        .conflict_count = conflict_count,
    };
}

fn findOrAppendState(
    allocator: std.mem.Allocator,
    states: *std.array_list.Managed(StateBuilder),
    items: []const Item,
    rules: []const RuleTable,
) !u16 {
    for (states.items, 0..) |state, idx| {
        if (itemSlicesEqual(state.items, items)) return @intCast(idx);
    }

    try states.append(.{
        .items = try allocator.dupe(Item, items),
        .transitions = std.array_list.Managed(Transition).init(allocator),
        .has_accept_item = stateHasAcceptItem(rules, items),
    });
    return @intCast(states.items.len - 1);
}

fn stateHasAcceptItem(rules: []const RuleTable, items: []const Item) bool {
    for (items) |item| {
        if (item.rule_index != 0) continue;
        if (item.dot == rules[0].rhs_len) return true;
    }
    return false;
}

fn closureItems(
    allocator: std.mem.Allocator,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
    seed: []const Item,
) ![]Item {
    var items = std.array_list.Managed(Item).init(allocator);
    defer items.deinit();
    try items.appendSlice(seed);

    var cursor: usize = 0;
    while (cursor < items.items.len) : (cursor += 1) {
        const item = items.items[cursor];
        const rhs = ruleRhs(rules, rhs_symbols, item.rule_index);
        if (item.dot >= rhs.len) continue;
        const symbol = rhs[item.dot];
        if (symbol.kind != .nonterminal) continue;

        for (rules, 0..) |rule, rule_index| {
            if (rule.lhs_nonterminal != symbol.index) continue;
            try appendUniqueItem(&items, .{
                .rule_index = @intCast(rule_index),
                .dot = 0,
            });
        }
    }

    sortItems(items.items);
    return try items.toOwnedSlice();
}

fn gotoItems(
    allocator: std.mem.Allocator,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
    state_items: []const Item,
    symbol: SymbolRef,
) ![]Item {
    var moved = std.array_list.Managed(Item).init(allocator);
    defer moved.deinit();

    for (state_items) |item| {
        const rhs = ruleRhs(rules, rhs_symbols, item.rule_index);
        if (item.dot >= rhs.len) continue;
        if (!symbolEquals(rhs[item.dot], symbol)) continue;
        try moved.append(.{
            .rule_index = item.rule_index,
            .dot = item.dot + 1,
        });
    }
    if (moved.items.len == 0) return try allocator.alloc(Item, 0);

    const closed = try closureItems(allocator, rules, rhs_symbols, moved.items);
    return closed;
}

fn computeNullable(
    allocator: std.mem.Allocator,
    total_nonterminals: usize,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
) ![]bool {
    const nullable = try allocator.alloc(bool, total_nonterminals);
    @memset(nullable, false);

    var changed = true;
    while (changed) {
        changed = false;
        for (rules, 0..) |rule, rule_index| {
            const rhs = ruleRhs(rules, rhs_symbols, @intCast(rule_index));
            var all_nullable = rhs.len == 0;
            if (rhs.len != 0) {
                all_nullable = true;
                for (rhs) |symbol| {
                    if (symbol.kind == .terminal or !nullable[symbol.index]) {
                        all_nullable = false;
                        break;
                    }
                }
            }
            if (all_nullable and !nullable[rule.lhs_nonterminal]) {
                nullable[rule.lhs_nonterminal] = true;
                changed = true;
            }
        }
    }
    return nullable;
}

fn computeFirst(
    allocator: std.mem.Allocator,
    total_nonterminals: usize,
    total_terminals: usize,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
    nullable: []const bool,
) ![]bool {
    const first = try allocator.alloc(bool, total_nonterminals * total_terminals);
    @memset(first, false);

    var changed = true;
    while (changed) {
        changed = false;
        for (rules, 0..) |rule, rule_index| {
            const rhs = ruleRhs(rules, rhs_symbols, @intCast(rule_index));
            for (rhs) |symbol| {
                switch (symbol.kind) {
                    .terminal => {
                        changed = matrixSet(first, total_terminals, rule.lhs_nonterminal, symbol.index) or changed;
                        break;
                    },
                    .nonterminal => {
                        changed = matrixUnion(first, total_terminals, rule.lhs_nonterminal, first, symbol.index) or changed;
                        if (!nullable[symbol.index]) break;
                    },
                }
            }
        }
    }
    return first;
}

fn computeFollow(
    allocator: std.mem.Allocator,
    total_nonterminals: usize,
    total_terminals: usize,
    rules: []const RuleTable,
    rhs_symbols: []const SymbolRef,
    nullable: []const bool,
    first: []const bool,
    start_nonterminal: u16,
    end_terminal: u16,
) ![]bool {
    const follow = try allocator.alloc(bool, total_nonterminals * total_terminals);
    @memset(follow, false);
    _ = matrixSet(follow, total_terminals, start_nonterminal, end_terminal);

    var changed = true;
    while (changed) {
        changed = false;
        for (rules, 0..) |rule, rule_index| {
            const rhs = ruleRhs(rules, rhs_symbols, @intCast(rule_index));
            for (rhs, 0..) |symbol, idx| {
                if (symbol.kind != .nonterminal) continue;

                const suffix = rhs[idx + 1 ..];
                if (suffix.len == 0) {
                    changed = matrixUnion(follow, total_terminals, symbol.index, follow, rule.lhs_nonterminal) or changed;
                    continue;
                }

                var suffix_nullable = true;
                for (suffix) |next_symbol| {
                    switch (next_symbol.kind) {
                        .terminal => {
                            changed = matrixSet(follow, total_terminals, symbol.index, next_symbol.index) or changed;
                            suffix_nullable = false;
                            break;
                        },
                        .nonterminal => {
                            changed = matrixUnion(follow, total_terminals, symbol.index, first, next_symbol.index) or changed;
                            if (!nullable[next_symbol.index]) {
                                suffix_nullable = false;
                                break;
                            }
                        },
                    }
                }
                if (suffix_nullable) {
                    changed = matrixUnion(follow, total_terminals, symbol.index, follow, rule.lhs_nonterminal) or changed;
                }
            }
        }
    }

    return follow;
}

fn mergeAction(
    entries: *std.array_list.Managed(ActionEntry),
    state: u16,
    terminal: u16,
    action: ParseAction,
    conflict_count: *usize,
) !void {
    for (entries.items) |*entry| {
        if (entry.state != state or entry.terminal != terminal) continue;
        if (!actionEquals(entry.action, action)) {
            conflict_count.* += 1;
            entry.action = preferAction(entry.action, action);
        }
        return;
    }
    try entries.append(.{
        .state = state,
        .terminal = terminal,
        .action = action,
    });
}

fn preferAction(current: ParseAction, incoming: ParseAction) ParseAction {
    return switch (current) {
        .accept => current,
        .shift => current,
        .reduce => switch (incoming) {
            .accept => incoming,
            .shift => incoming,
            .reduce => |incoming_rule| switch (current) {
                .reduce => |current_rule| if (incoming_rule < current_rule) incoming else current,
                else => unreachable,
            },
        },
    };
}

fn actionEquals(lhs: ParseAction, rhs: ParseAction) bool {
    return switch (lhs) {
        .accept => rhs == .accept,
        .shift => |value| switch (rhs) {
            .shift => |other| value == other,
            else => false,
        },
        .reduce => |value| switch (rhs) {
            .reduce => |other| value == other,
            else => false,
        },
    };
}

fn appendUniqueItem(items: *std.array_list.Managed(Item), item: Item) !void {
    for (items.items) |existing| {
        if (existing.rule_index == item.rule_index and existing.dot == item.dot) return;
    }
    try items.append(item);
}

fn appendUniqueSymbol(symbols: *std.array_list.Managed(SymbolRef), symbol: SymbolRef) !void {
    for (symbols.items) |existing| {
        if (symbolEquals(existing, symbol)) return;
    }
    try symbols.append(symbol);
}

fn symbolEquals(lhs: SymbolRef, rhs: SymbolRef) bool {
    return lhs.kind == rhs.kind and lhs.index == rhs.index;
}

fn itemSlicesEqual(lhs: []const Item, rhs: []const Item) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |lhs_item, rhs_item| {
        if (lhs_item.rule_index != rhs_item.rule_index or lhs_item.dot != rhs_item.dot) return false;
    }
    return true;
}

fn sortItems(items: []Item) void {
    std.sort.block(Item, items, {}, struct {
        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            if (lhs.rule_index == rhs.rule_index) return lhs.dot < rhs.dot;
            return lhs.rule_index < rhs.rule_index;
        }
    }.lessThan);
}

fn ruleRhs(rules: []const RuleTable, rhs_symbols: []const SymbolRef, rule_index: u16) []const SymbolRef {
    const rule = rules[rule_index];
    return rhs_symbols[rule.rhs_start .. rule.rhs_start + rule.rhs_len];
}

fn matrixIndex(width: usize, row: u16, column: u16) usize {
    return @as(usize, row) * width + column;
}

fn matrixHas(matrix: []const bool, width: usize, row: u16, column: u16) bool {
    return matrix[matrixIndex(width, row, column)];
}

fn matrixSet(matrix: []bool, width: usize, row: u16, column: u16) bool {
    const idx = matrixIndex(width, row, column);
    if (matrix[idx]) return false;
    matrix[idx] = true;
    return true;
}

fn matrixUnion(dst: []bool, width: usize, dst_row: u16, src: []const bool, src_row: u16) bool {
    var changed = false;
    var column: usize = 0;
    while (column < width) : (column += 1) {
        const src_idx = matrixIndex(width, src_row, @intCast(column));
        if (!src[src_idx]) continue;
        changed = matrixSet(dst, width, dst_row, @intCast(column)) or changed;
    }
    return changed;
}

fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (std.ascii.isPrint(byte)) {
                try writer.writeByte(byte);
            } else {
                try writer.print("\\x{X:0>2}", .{byte});
            }
        },
    };
    try writer.writeByte('"');
}

test "parser generator emits lemon-style metadata skeleton" {
    const alloc = std.testing.allocator;
    const sydraql = @import("grammars/sydraql_core.zig").spec;
    var gen = ParserGenerator.init(alloc);
    const artifact = try gen.emit(sydraql);
    defer alloc.free(artifact.emitted_source);

    try std.testing.expectEqualStrings("sydraql_core", artifact.grammar_name);
    try std.testing.expectEqualStrings("SydraqlGeneratedParser", artifact.parser_name);
    try std.testing.expect(artifact.state_count_hint >= sydraql.rules.len);
    try std.testing.expect(artifact.fallback_count != 0);
    try std.testing.expect(std.mem.indexOf(u8, artifact.emitted_source, "pub const fallbacks") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.emitted_source, "coverage_hook_name") != null);
}

test "parser generator handles SQL core grammar skeleton" {
    const alloc = std.testing.allocator;
    const sql_core = @import("grammars/sql_core_ts.zig").spec;
    var gen = ParserGenerator.init(alloc);
    const artifact = try gen.emit(sql_core);
    defer alloc.free(artifact.emitted_source);

    try std.testing.expectEqualStrings("sql_core_ts", artifact.grammar_name);
    try std.testing.expectEqualStrings("SqlCoreGeneratedParser", artifact.parser_name);
    try std.testing.expect(std.mem.indexOf(u8, artifact.emitted_source, "\"select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.emitted_source, "\"stmt_list\"") != null);
}

test "generated parser runtime accepts simple sydraql select" {
    const alloc = std.testing.allocator;
    const sydraql = @import("grammars/sydraql_core.zig").spec;
    var gen = ParserGenerator.init(alloc);
    var tables = try gen.buildTables(sydraql);
    defer tables.deinit(alloc);

    var parser = try GeneratedParser.init(alloc, &tables, .{});
    defer parser.deinit();

    const terminals = [_]u16{
        tables.terminalId("select") orelse return error.InvalidCharacter,
        tables.terminalId("number") orelse return error.InvalidCharacter,
        tables.terminalId("eof") orelse return error.InvalidCharacter,
    };
    var result = try parser.parse(terminals[0..]);
    defer result.deinit(alloc);

    try std.testing.expect(result.accepted);
    try std.testing.expect(result.reductions.len != 0);
}

test "generated parser runtime applies fallback terminals" {
    const alloc = std.testing.allocator;
    const sydraql = @import("grammars/sydraql_core.zig").spec;
    var gen = ParserGenerator.init(alloc);
    var tables = try gen.buildTables(sydraql);
    defer tables.deinit(alloc);

    var parser = try GeneratedParser.init(alloc, &tables, .{});
    defer parser.deinit();

    const terminals = [_]u16{
        tables.terminalId("select") orelse return error.InvalidCharacter,
        tables.terminalId("time") orelse return error.InvalidCharacter,
        tables.terminalId("eof") orelse return error.InvalidCharacter,
    };
    var result = try parser.parse(terminals[0..]);
    defer result.deinit(alloc);

    try std.testing.expect(result.accepted);
    try std.testing.expect(result.fallback_count > 0);
}

test "generated parser runtime accepts SQL core select" {
    const alloc = std.testing.allocator;
    const sql_core = @import("grammars/sql_core_ts.zig").spec;
    var gen = ParserGenerator.init(alloc);
    var tables = try gen.buildTables(sql_core);
    defer tables.deinit(alloc);

    var parser = try GeneratedParser.init(alloc, &tables, .{});
    defer parser.deinit();

    const terminals = [_]u16{
        tables.terminalId("select") orelse return error.InvalidCharacter,
        tables.terminalId("star") orelse return error.InvalidCharacter,
        tables.terminalId("from") orelse return error.InvalidCharacter,
        tables.terminalId("identifier") orelse return error.InvalidCharacter,
        tables.terminalId("eof") orelse return error.InvalidCharacter,
    };
    var result = try parser.parse(terminals[0..]);
    defer result.deinit(alloc);

    try std.testing.expect(result.accepted);
    try std.testing.expect(tables.states.len > 1);
}

test "generated parser runtime records parse failure location" {
    const alloc = std.testing.allocator;
    const sql_core = @import("grammars/sql_core_ts.zig").spec;
    var gen = ParserGenerator.init(alloc);
    var tables = try gen.buildTables(sql_core);
    defer tables.deinit(alloc);

    var parser = try GeneratedParser.init(alloc, &tables, .{});
    defer parser.deinit();

    const terminals = [_]u16{
        tables.terminalId("select") orelse return error.InvalidCharacter,
        tables.terminalId("from") orelse return error.InvalidCharacter,
        tables.terminalId("identifier") orelse return error.InvalidCharacter,
        tables.terminalId("eof") orelse return error.InvalidCharacter,
    };
    try std.testing.expectError(error.ParseError, parser.parse(terminals[0..]));
    const failure = parser.failureInfo() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FailureReason.unexpected_token, failure.reason);
    try std.testing.expectEqual(@as(usize, 1), failure.token_index);
}

test "generated parser runtime honors conditional rules and emits coverage events" {
    const alloc = std.testing.allocator;
    const test_spec = grammar.GrammarSpec{
        .name = "conditional_test",
        .parser_name = "ConditionalParser",
        .start_symbol = "stmt",
        .tokens = &.{
            .{ .name = "select" },
            .{ .name = "number" },
            .{ .name = "eof" },
        },
        .nonterminals = &.{
            "stmt",
        },
        .rules = &.{
            .{ .lhs = "stmt", .rhs = &.{ "select", "number" }, .action = "emitSelect()", .condition = "allow_select", .destructor = "destroySelect()" },
        },
    };

    var gen = ParserGenerator.init(alloc);
    var tables = try gen.buildTables(test_spec);
    defer tables.deinit(alloc);

    try std.testing.expectEqualStrings("destroySelect()", tables.rules[1].destructor.?);

    const HooksCtx = struct {
        allow_rule: bool,
        coverage_events: usize = 0,

        fn ruleEnabled(ctx: ?*anyopaque, _: usize, condition: ?[]const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (condition == null) return true;
            return self.allow_rule;
        }

        fn coverage(ctx: ?*anyopaque, _: u16, _: CoverageEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.coverage_events += 1;
        }
    };

    const terminals = [_]u16{
        tables.terminalId("select") orelse return error.InvalidCharacter,
        tables.terminalId("number") orelse return error.InvalidCharacter,
    };

    var blocked_ctx = HooksCtx{ .allow_rule = false };
    var blocked = try GeneratedParser.init(alloc, &tables, .{
        .context = &blocked_ctx,
        .rule_enabled = HooksCtx.ruleEnabled,
        .coverage = HooksCtx.coverage,
    });
    defer blocked.deinit();
    try std.testing.expectError(error.DisabledRule, blocked.parse(terminals[0..]));
    const blocked_failure = blocked.failureInfo() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FailureReason.disabled_rule, blocked_failure.reason);

    var allowed_ctx = HooksCtx{ .allow_rule = true };
    var allowed = try GeneratedParser.init(alloc, &tables, .{
        .context = &allowed_ctx,
        .rule_enabled = HooksCtx.ruleEnabled,
        .coverage = HooksCtx.coverage,
    });
    defer allowed.deinit();
    var result = try allowed.parse(terminals[0..]);
    defer result.deinit(alloc);
    try std.testing.expect(result.accepted);
    try std.testing.expect(allowed_ctx.coverage_events > 0);
}
