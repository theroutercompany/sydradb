---
sidebar_position: 9
title: src/sydra/query/functions.zig
---

# `src/sydra/query/functions.zig`

## Purpose

Defines the sydraQL function registry and type-checking rules used by:

- validation (`validator.zig`)
- type inference (`type_inference.zig`)
- (indirectly) execution/planning decisions via planner hints

## See also

- [Validator](./validator.md)
- [Type inference](./type-inference.md)
- [Expression evaluation](./expression.md)

## Definition index (public)

### `pub const FunctionKind = enum { ... }`

- `scalar`
- `aggregate`
- `window`
- `fill`

### `pub const TypeTag = enum { ... }`

```text
any, null, boolean, integer, float, numeric, value, string, timestamp, duration, tags
```

Notes:

- `numeric` and `value` are “widening” tags that accept multiple runtime shapes (see `Expectation.tagAccepts` in the implementation).

### `pub const Type = struct { ... }`

- `tag: TypeTag`
- `nullable: bool`

Helpers:

- `Type.init(tag, nullable)`
- `Type.nonNull()` — same tag, `nullable = false`

### `pub const Expectation = struct { ... }`

Used to type-check a single argument position.

- `label: []const u8` — used for error messages and docs
- `allowed: []const TypeTag` — empty slice means “any”
- `allow_nullable: bool` (default `true`)

Key method:

- `matches(actual: Type) bool` — validates `nullable` policy and checks tags via `tagAccepts`

Tag acceptance rules (high-level):

- `any` matches everything
- `numeric` accepts `numeric|float|integer|value`
- `value` accepts `value|numeric|float|integer`
- `duration` accepts `duration|numeric|float|integer|value`
- `timestamp` accepts `timestamp|value`

### `pub const ParamSpec = struct { ... }`

- `expectation: Expectation`
- `optional: bool` — default `false`
- `variadic: bool` — default `false` (when true, the last param repeats)

### `pub const ReturnStrategy = union(enum) { ... }`

- `fixed: Type`
- `same_as: { index: usize, force_non_nullable: bool = false }`

### `pub const PlannerHints = struct { ... }`

Hints for later stages:

- `streaming: bool = true`
- `requires_sorted_input: bool = false`
- `needs_window_frame: bool = false`
- `bucket_sensitive: bool = false`

### `pub const FunctionSignature = struct { ... }`

- `name: []const u8`
- `kind: FunctionKind`
- `params: []const ParamSpec`
- `return_strategy: ReturnStrategy`
- `hints: PlannerHints = .{}`

Helpers:

- `requiredArgs() usize` — counts non-optional params (variadic counts as 1 if non-optional)
- `maxArgs() ?usize` — returns `null` for variadic signatures
- `infer(args: []const Type) !Type` — validates arity/types and computes the return type

### `pub const TypeCheckError = error { ... }`

- `UnknownFunction`
- `ArityMismatch`
- `TypeMismatch`

### `pub const FunctionMatch = struct { ... }`

- `signature: *const FunctionSignature`
- `return_type: Type`

## Public API

### `pub fn registry() []const FunctionSignature`

Returns the builtin registry (array of signatures).

### `pub fn lookup(name: []const u8) ?*const FunctionSignature`

Case-insensitive lookup by function name.

### `pub fn resolve(name: []const u8, args: []const Type) !FunctionMatch`

Performs arity/type validation and returns the matched signature plus inferred return type.

### `pub fn displayName(ty: Type) []const u8`

Human-readable type name used in API responses.

### `pub fn pgTypeInfo(ty: Type) PgTypeInfo`

Maps a type to PostgreSQL OID/length/modifier information (used by pgwire surfaces).

### `pub const PgTypeInfo = struct { ... }`

- `oid: u32` — PostgreSQL type OID
- `len: i16` — type length (`-1` for varlena)
- `modifier: i32` — type modifier (usually `-1`)
- `format: u16 = 0` — text (`0`) vs binary (`1`) format hint

## Builtins (as implemented)

Builtins are defined in a static array (`builtin_registry`) with per-function:

- parameter expectations (including optional/variadic)
- return strategy (fixed or derived from an argument)
- planner hints (e.g. sorted-input requirements for `first`/`last`)

### Registry table

| Name | Kind | Params | Return | Notes |
|---|---|---|---|---|
| `avg` | aggregate | `numeric` | `float?` | nullable result |
| `sum` | aggregate | `numeric` | same as arg0 |  |
| `min` | aggregate | `numeric` | same as arg0 |  |
| `max` | aggregate | `numeric` | same as arg0 |  |
| `count` | aggregate | `[any]?` | `integer` | accepts zero args |
| `last` | aggregate | `numeric` | same as arg0 | requires sorted input |
| `first` | aggregate | `numeric` | same as arg0 | requires sorted input |
| `percentile` | aggregate | `numeric, float` | `float?` | non-streaming; sorted input |
| `abs` | scalar | `numeric (non-null)` | `float` |  |
| `ceil` | scalar | `numeric (non-null)` | `float` |  |
| `floor` | scalar | `numeric (non-null)` | `float` |  |
| `round` | scalar | `numeric (non-null)` | `float` |  |
| `pow` | scalar | `numeric (non-null), numeric (non-null)` | `float` |  |
| `ln` | scalar | `numeric (non-null)` | `float` |  |
| `sqrt` | scalar | `numeric (non-null)` | `float` |  |
| `now` | scalar | _(none)_ | `timestamp` |  |
| `time_bucket` | scalar | `duration, timestamp[, timestamp]` | `timestamp` | bucket-sensitive |
| `lag` | window | `any[, integer]` | same as arg0 | requires sorted input; needs window frame |
| `lead` | window | `any[, integer]` | same as arg0 | requires sorted input; needs window frame |
| `rate` | aggregate | `numeric` | `float?` | requires sorted input; bucket-sensitive |
| `irate` | aggregate | `numeric` | `float?` | requires sorted input; bucket-sensitive |
| `delta` | aggregate | `numeric` | `float?` | requires sorted input |
| `integral` | aggregate | `numeric` | `float?` | requires sorted input; bucket-sensitive |
| `moving_avg` | window | `numeric, duration` | `float?` | requires sorted input; needs window frame |
| `ema` | window | `numeric, duration, float` | `float?` | requires sorted input; needs window frame |
| `coalesce` | fill | `any...` | same as arg0 (forced non-null) | variadic |
| `fill_forward` | fill | `numeric` | same as arg0 |  |

## Code excerpt

```zig title="src/sydra/query/functions.zig (signature inference + resolve excerpt)"
pub const FunctionSignature = struct {
    name: []const u8,
    kind: FunctionKind,
    params: []const ParamSpec,
    return_strategy: ReturnStrategy,
    hints: PlannerHints = .{},

    pub fn infer(self: *const FunctionSignature, args: []const Type) TypeCheckError!Type {
        const min_args = self.requiredArgs();
        if (args.len < min_args) return TypeCheckError.ArityMismatch;

        if (self.maxArgs()) |max_args| {
            if (args.len > max_args) return TypeCheckError.ArityMismatch;
        }

        var idx: usize = 0;
        while (idx < args.len) : (idx += 1) {
            const spec = try self.specForIndex(idx);
            if (!spec.expectation.matches(args[idx])) {
                return TypeCheckError.TypeMismatch;
            }
        }

        return switch (self.return_strategy) {
            .fixed => |t| t,
            .same_as => |info| blk: {
                if (info.index >= args.len) return TypeCheckError.ArityMismatch;
                var ty = args[info.index];
                if (info.force_non_nullable) {
                    ty = ty.nonNull();
                }
                break :blk ty;
            },
        };
    }
};

pub fn resolve(name: []const u8, args: []const Type) TypeCheckError!FunctionMatch {
    const entry = lookup(name) orelse return TypeCheckError.UnknownFunction;
    const return_type = try entry.infer(args);
    return FunctionMatch{ .signature = entry, .return_type = return_type };
}
```
