test "engine and HTTP runtime modules are in the aggregate test graph" {
    _ = @import("sydra/engine.zig");
    _ = @import("sydra/http.zig");
    _ = @import("sydra/server.zig");
}
