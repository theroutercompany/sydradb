---
sidebar_position: 2
title: examples/loadgen.zig
---

# `examples/loadgen.zig`

## Purpose

Generates a small NDJSON stream that matches SydraDB’s ingest shape:

```json
{"series":"weather.room1","ts":1694300000,"value":20.00}
```

This is primarily useful for quick smoke tests of the ingest path (via stdin piping).

## Public API

### `pub fn main() !void`

Behavior:

- Creates a `GeneralPurposeAllocator`.
- Writes 10,000 lines to stdout.
- Starts at `ts = 1694300000` and increments by `10` per line.
- Uses a repeating value pattern:
  - `val = 20.0 + (i % 100) / 10.0`

Implementation notes:

- Each line is built using `std.fmt.allocPrint` and printed with `stdout.print(...)`.
- The allocations are not freed per-line (the program exits immediately after generation).

## Example usage

Pipe into the CLI ingest subcommand:

```sh
zig run examples/loadgen.zig | ./zig-out/bin/sydradb ingest
```

