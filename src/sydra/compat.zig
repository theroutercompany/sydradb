pub const stats = @import("compat/stats.zig");
pub const sqlstate = @import("compat/sqlstate.zig");
pub const clog = @import("compat/log.zig");
pub const fixtures = struct {
    pub const translator = @import("compat/fixtures/translator.zig");
};
pub const catalog = @import("compat/catalog.zig");
pub const wire = @import("compat/wire.zig");
