pub const TokenSpec = struct {
    name: []const u8,
    fallback: ?[]const u8 = null,
};

pub const RuleSpec = struct {
    lhs: []const u8,
    rhs: []const []const u8,
    action: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    destructor: ?[]const u8 = null,
};

pub const GrammarSpec = struct {
    name: []const u8,
    parser_name: []const u8,
    start_symbol: []const u8,
    tokens: []const TokenSpec,
    nonterminals: []const []const u8,
    rules: []const RuleSpec,
    coverage_hook_name: ?[]const u8 = null,
};
