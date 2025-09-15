// Thin zstd wrapper (placeholder). In production, link FFI or subprocess.
pub fn compress(_: anytype, _: []const u8) []const u8 { return &[_]u8{}; }
pub fn decompress(_: anytype, _: []const u8) []const u8 { return &[_]u8{}; }
