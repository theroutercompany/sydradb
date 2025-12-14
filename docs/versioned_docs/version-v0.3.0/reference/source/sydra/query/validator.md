---
sidebar_position: 7
title: src/sydra/query/validator.zig
---

# `src/sydra/query/validator.zig`

## Purpose

Performs semantic checks over the AST and produces diagnostics.

This stage is used by `exec.execute` before planning.

## Definition index (public)

### `pub const AnalyzeResult`

- `diagnostics: DiagnosticList`
- `is_valid: bool`

### `pub const AnalyzeError`

Alias:

- `std.mem.Allocator.Error`

### `pub const Analyzer`

Methods:

- `Analyzer.init(allocator)`
- `analyze(statement)` → `AnalyzeResult`
- `deinit(result)` – frees diagnostic messages and list storage

## Key validations (as implemented)

### Time predicate requirement

`SELECT` and `DELETE` require a time predicate:

- If `WHERE` is missing, the analyzer emits `time_range_required`.
- If `WHERE` exists but does not reference `time`, the analyzer emits `time_range_required`.

The analyzer detects “time” references by scanning identifiers and treating an identifier as “time” when its trailing segment (after the last `.`) equals `time` case-insensitively.

### Function name validation

For any call expression, the analyzer checks:

- `functions.lookup(call.callee.value) != null`

Unknown functions emit `invalid_syntax` with a message like `unknown function 'foo'`.

## Internal structure (non-public)

Important internal helpers in the implementation:

- `validateStatement` dispatches on `ast.Statement` variants.
- `validateSelect` enforces the time predicate and walks projections/groupings/fill/order expressions.
- `validateInsert` walks `VALUES (...)` expressions.
- `validateDelete` enforces the time predicate and walks the predicate.
- `visitExpression` walks expressions and returns a boolean indicating whether the expression references `time`.
- Span helpers:
  - `exprSpan`, `exprStart`, `exprEnd` compute spans for nested expressions.

Time detection:

- An identifier is treated as “time” when its trailing segment (after `.`) equals `time` case-insensitively.

## Code excerpt

```zig title="src/sydra/query/validator.zig (time predicate + unknown function check excerpt)"
pub fn analyze(self: *Analyzer, statement: *ast.Statement) AnalyzeError!AnalyzeResult {
    var result = AnalyzeResult{};
    try self.validateStatement(statement, &result);
    result.is_valid = result.diagnostics.items.len == 0;
    return result;
}

fn validateSelect(self: *Analyzer, select: *const ast.Select, result: *AnalyzeResult) AnalyzeError!void {
    var predicate_has_time = false;
    if (select.predicate) |pred| {
        predicate_has_time = try self.visitExpression(pred, result);
        if (!predicate_has_time) {
            try self.addDiagnostic(result, .time_range_required, "time range predicate is required", exprSpan(pred));
        }
    } else {
        try self.addDiagnostic(result, .time_range_required, "select requires time predicate", select.span);
    }

    for (select.projections) |proj| {
        _ = try self.visitExpression(proj.expr, result);
    }
}

fn visitExpression(self: *Analyzer, expr: *const ast.Expr, result: *AnalyzeResult) AnalyzeError!bool {
    return switch (expr.*) {
        .identifier => |ident| {
            return identifierIsTime(ident);
        },
        .literal => |literal| {
            _ = literal;
            return false;
        },
        .unary => |unary| {
            return try self.visitExpression(unary.operand, result);
        },
        .binary => |binary| {
            const left = try self.visitExpression(binary.left, result);
            const right = try self.visitExpression(binary.right, result);
            return left or right;
        },
        .call => |call| {
            var has_time = false;
            for (call.args) |arg| {
                if (try self.visitExpression(arg, result)) {
                    has_time = true;
                }
            }

            if (functions.lookup(call.callee.value) == null) {
                const msg = try std.fmt.allocPrint(self.allocator, "unknown function '{s}'", .{call.callee.value});
                defer self.allocator.free(msg);
                try self.addDiagnostic(result, .invalid_syntax, msg, call.span);
            }

            return has_time;
        },
    };
}
```
