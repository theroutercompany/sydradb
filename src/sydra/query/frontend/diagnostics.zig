const common = @import("../common.zig");

pub const DiagnosticCode = enum {
    invalid_literal,
    unexpected_token,
    unexpected_eof,
    grammar_conflict,
    lexer_mismatch,
    parser_mismatch,
    unsupported_feature,
};

pub const DiagnosticPhase = enum {
    lex,
    parse,
    normalize,
    bind,
    codegen,
    vm,
};

pub const Diagnostic = struct {
    code: DiagnosticCode,
    message: []const u8,
    span: ?common.Span = null,
    phase: DiagnosticPhase,
};
