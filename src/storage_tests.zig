test "phase 1 native market storage modules are in the aggregate test graph" {
    _ = @import("sydra/storage/market_identity.zig");
    _ = @import("sydra/storage/market_migration.zig");
    _ = @import("sydra/storage/market_catalog.zig");
    _ = @import("sydra/storage/market_compact.zig");
    _ = @import("sydra/storage/market_memtable.zig");
    _ = @import("sydra/storage/market_manifest.zig");
    _ = @import("sydra/storage/market_reader.zig");
    _ = @import("sydra/storage/market_segment.zig");
    _ = @import("sydra/storage/repository_lock.zig");
    _ = @import("sydra/storage/wal.zig");
}
