const std = @import("std");
const cfg = @import("../config.zig");

pub const path = "market_catalog.json";

pub const StorageMapping = enum {
    fanout_v1,

    pub fn parse(input_text: []const u8) ?StorageMapping {
        if (std.ascii.eqlIgnoreCase(input_text, "fanout_v1")) return .fanout_v1;
        return null;
    }

    pub fn text(self: StorageMapping) []const u8 {
        return @tagName(self);
    }
};

pub const RollupTransformKind = enum {
    trade_to_bar,
    quote_to_spread_mid,
    bar_to_bar,

    pub fn parse(input_text: []const u8) ?RollupTransformKind {
        if (std.ascii.eqlIgnoreCase(input_text, "trade_to_bar")) return .trade_to_bar;
        if (std.ascii.eqlIgnoreCase(input_text, "quote_to_spread_mid")) return .quote_to_spread_mid;
        if (std.ascii.eqlIgnoreCase(input_text, "bar_to_bar")) return .bar_to_bar;
        return null;
    }

    pub fn text(self: RollupTransformKind) []const u8 {
        return @tagName(self);
    }
};

pub const SignalExpressionKind = enum {
    ema,
    moving_avg,
    crossover,
    crossunder,
    threshold_cross,
    spread_gt,
    vwap_deviation,

    pub fn parse(input_text: []const u8) ?SignalExpressionKind {
        inline for (std.meta.fields(SignalExpressionKind)) |field| {
            if (std.ascii.eqlIgnoreCase(input_text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: SignalExpressionKind) []const u8 {
        return @tagName(self);
    }
};

pub const MarketSchema = struct {
    metric: []u8,
    ordered_columns: [][]u8,
    required_labels: [][]u8,
    storage_mapping: StorageMapping = .fanout_v1,

    pub fn clone(self: MarketSchema, alloc: std.mem.Allocator) !MarketSchema {
        return .{
            .metric = try alloc.dupe(u8, self.metric),
            .ordered_columns = try cloneStringArray(alloc, self.ordered_columns),
            .required_labels = try cloneStringArray(alloc, self.required_labels),
            .storage_mapping = self.storage_mapping,
        };
    }

    pub fn deinit(self: *MarketSchema, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        freeStringArray(alloc, self.ordered_columns);
        freeStringArray(alloc, self.required_labels);
        self.* = undefined;
    }

    pub fn eql(self: MarketSchema, other: MarketSchema) bool {
        return std.mem.eql(u8, self.metric, other.metric) and
            stringArrayEql(self.ordered_columns, other.ordered_columns) and
            stringArrayEql(self.required_labels, other.required_labels) and
            self.storage_mapping == other.storage_mapping;
    }
};

pub const MarketSchemaInput = struct {
    metric: []const u8,
    ordered_columns: []const []const u8,
    required_labels: []const []const u8,
    storage_mapping: StorageMapping = .fanout_v1,
};

pub const BarPolicy = struct {
    id: []u8,
    version: u32,
    source_metric: []u8,
    interval_ns: i64,
    session_rule: []u8,
    no_trade_rule: []u8,
    halt_rule: []u8,
    correction_policy: []u8,
    trade_filter: ?[]u8 = null,

    pub fn clone(self: BarPolicy, alloc: std.mem.Allocator) !BarPolicy {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .version = self.version,
            .source_metric = try alloc.dupe(u8, self.source_metric),
            .interval_ns = self.interval_ns,
            .session_rule = try alloc.dupe(u8, self.session_rule),
            .no_trade_rule = try alloc.dupe(u8, self.no_trade_rule),
            .halt_rule = try alloc.dupe(u8, self.halt_rule),
            .correction_policy = try alloc.dupe(u8, self.correction_policy),
            .trade_filter = if (self.trade_filter) |value| try alloc.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *BarPolicy, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_metric);
        alloc.free(self.session_rule);
        alloc.free(self.no_trade_rule);
        alloc.free(self.halt_rule);
        alloc.free(self.correction_policy);
        if (self.trade_filter) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const BarPolicyInput = struct {
    id: []const u8,
    source_metric: []const u8,
    interval_ns: i64,
    session_rule: []const u8,
    no_trade_rule: []const u8,
    halt_rule: []const u8,
    correction_policy: []const u8,
    trade_filter: ?[]const u8 = null,
};

pub const RollupDefinition = struct {
    id: []u8,
    version: u32,
    source_metric: []u8,
    target_metric: []u8,
    policy_id: []u8,
    transform_kind: RollupTransformKind,

    pub fn clone(self: RollupDefinition, alloc: std.mem.Allocator) !RollupDefinition {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .version = self.version,
            .source_metric = try alloc.dupe(u8, self.source_metric),
            .target_metric = try alloc.dupe(u8, self.target_metric),
            .policy_id = try alloc.dupe(u8, self.policy_id),
            .transform_kind = self.transform_kind,
        };
    }

    pub fn deinit(self: *RollupDefinition, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.source_metric);
        alloc.free(self.target_metric);
        alloc.free(self.policy_id);
        self.* = undefined;
    }
};

pub const RollupDefinitionInput = struct {
    id: []const u8,
    source_metric: []const u8,
    target_metric: []const u8,
    policy_id: []const u8,
    transform_kind: RollupTransformKind,
};

pub const SignalDefinition = struct {
    id: []u8,
    version: u32,
    input_metric: []u8,
    policy_id: ?[]u8 = null,
    expression_kind: SignalExpressionKind,
    params_json: []u8,
    emit_rule: []u8,

    pub fn clone(self: SignalDefinition, alloc: std.mem.Allocator) !SignalDefinition {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .version = self.version,
            .input_metric = try alloc.dupe(u8, self.input_metric),
            .policy_id = if (self.policy_id) |value| try alloc.dupe(u8, value) else null,
            .expression_kind = self.expression_kind,
            .params_json = try alloc.dupe(u8, self.params_json),
            .emit_rule = try alloc.dupe(u8, self.emit_rule),
        };
    }

    pub fn deinit(self: *SignalDefinition, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.input_metric);
        if (self.policy_id) |value| alloc.free(value);
        alloc.free(self.params_json);
        alloc.free(self.emit_rule);
        self.* = undefined;
    }
};

pub const SignalDefinitionInput = struct {
    id: []const u8,
    input_metric: []const u8,
    policy_id: ?[]const u8 = null,
    expression_kind: SignalExpressionKind,
    params_json: []const u8,
    emit_rule: []const u8,
};

pub const Snapshot = struct {
    schemas: []MarketSchema,
    bar_policies: []BarPolicy,
    rollups: []RollupDefinition,
    signals: []SignalDefinition,

    pub fn empty(alloc: std.mem.Allocator) !Snapshot {
        return .{
            .schemas = try alloc.alloc(MarketSchema, 0),
            .bar_policies = try alloc.alloc(BarPolicy, 0),
            .rollups = try alloc.alloc(RollupDefinition, 0),
            .signals = try alloc.alloc(SignalDefinition, 0),
        };
    }

    pub fn clone(self: Snapshot, alloc: std.mem.Allocator) !Snapshot {
        var schemas = try alloc.alloc(MarketSchema, self.schemas.len);
        errdefer alloc.free(schemas);
        for (self.schemas, 0..) |entry, idx| schemas[idx] = try entry.clone(alloc);

        var bar_policies = try alloc.alloc(BarPolicy, self.bar_policies.len);
        errdefer {
            for (bar_policies[0..]) |*entry| entry.deinit(alloc);
            alloc.free(bar_policies);
        }
        for (self.bar_policies, 0..) |entry, idx| bar_policies[idx] = try entry.clone(alloc);

        var rollups = try alloc.alloc(RollupDefinition, self.rollups.len);
        errdefer {
            for (rollups[0..]) |*entry| entry.deinit(alloc);
            alloc.free(rollups);
        }
        for (self.rollups, 0..) |entry, idx| rollups[idx] = try entry.clone(alloc);

        var signals = try alloc.alloc(SignalDefinition, self.signals.len);
        errdefer {
            for (signals[0..]) |*entry| entry.deinit(alloc);
            alloc.free(signals);
        }
        for (self.signals, 0..) |entry, idx| signals[idx] = try entry.clone(alloc);

        return .{
            .schemas = schemas,
            .bar_policies = bar_policies,
            .rollups = rollups,
            .signals = signals,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.schemas) |*entry| entry.deinit(alloc);
        alloc.free(self.schemas);
        for (self.bar_policies) |*entry| entry.deinit(alloc);
        alloc.free(self.bar_policies);
        for (self.rollups) |*entry| entry.deinit(alloc);
        alloc.free(self.rollups);
        for (self.signals) |*entry| entry.deinit(alloc);
        alloc.free(self.signals);
    }
};

pub const Catalog = struct {
    alloc: std.mem.Allocator,
    fsync: cfg.FsyncPolicy,
    root: ?std.fs.Dir = null,
    mutex: std.Thread.Mutex = .{},
    schemas: std.array_list.Managed(MarketSchema),
    bar_policies: std.array_list.Managed(BarPolicy),
    rollups: std.array_list.Managed(RollupDefinition),
    signals: std.array_list.Managed(SignalDefinition),

    pub fn initEmpty(alloc: std.mem.Allocator, fsync: cfg.FsyncPolicy) Catalog {
        return .{
            .alloc = alloc,
            .fsync = fsync,
            .schemas = std.array_list.Managed(MarketSchema).init(alloc),
            .bar_policies = std.array_list.Managed(BarPolicy).init(alloc),
            .rollups = std.array_list.Managed(RollupDefinition).init(alloc),
            .signals = std.array_list.Managed(SignalDefinition).init(alloc),
        };
    }

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !Catalog {
        var root = try data_dir.openDir(".", .{ .iterate = true });
        errdefer root.close();
        var catalog = Catalog.initEmpty(alloc, fsync);
        catalog.root = root;
        errdefer catalog.deinit();

        const body = catalog.root.?.readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (body) |buf| alloc.free(buf);

        if (body) |buf| try catalog.loadFromJson(buf);
        try catalog.ensureBuiltinSchemasLocked();
        if (catalog.root != null) try catalog.rewriteLocked();
        return catalog;
    }

    pub fn initFromSnapshot(
        alloc: std.mem.Allocator,
        data_dir: std.fs.Dir,
        fsync: cfg.FsyncPolicy,
        snapshot: Snapshot,
    ) !Catalog {
        var root = try data_dir.openDir(".", .{ .iterate = true });
        errdefer root.close();
        var catalog = Catalog.initEmpty(alloc, fsync);
        catalog.root = root;
        errdefer catalog.deinit();

        for (snapshot.schemas) |entry| try catalog.schemas.append(try entry.clone(alloc));
        for (snapshot.bar_policies) |entry| try catalog.bar_policies.append(try entry.clone(alloc));
        for (snapshot.rollups) |entry| try catalog.rollups.append(try entry.clone(alloc));
        for (snapshot.signals) |entry| try catalog.signals.append(try entry.clone(alloc));
        try catalog.ensureBuiltinSchemasLocked();
        return catalog;
    }

    pub fn deinit(self: *Catalog) void {
        for (self.schemas.items) |*entry| entry.deinit(self.alloc);
        self.schemas.deinit();
        for (self.bar_policies.items) |*entry| entry.deinit(self.alloc);
        self.bar_policies.deinit();
        for (self.rollups.items) |*entry| entry.deinit(self.alloc);
        self.rollups.deinit();
        for (self.signals.items) |*entry| entry.deinit(self.alloc);
        self.signals.deinit();
        if (self.root) |*root| root.close();
        self.* = undefined;
    }

    pub fn snapshotClone(self: *Catalog) !Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .schemas = try cloneEntrySlice(self.alloc, MarketSchema, self.schemas.items),
            .bar_policies = try cloneEntrySlice(self.alloc, BarPolicy, self.bar_policies.items),
            .rollups = try cloneEntrySlice(self.alloc, RollupDefinition, self.rollups.items),
            .signals = try cloneEntrySlice(self.alloc, SignalDefinition, self.signals.items),
        };
    }

    pub fn getSchema(self: *Catalog, metric: []const u8) ?MarketSchema {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.schemas.items) |entry| {
            if (std.mem.eql(u8, entry.metric, metric)) return entry.clone(self.alloc) catch return null;
        }
        return null;
    }

    pub fn listSchemas(self: *Catalog) ![]MarketSchema {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try cloneEntrySlice(self.alloc, MarketSchema, self.schemas.items);
    }

    pub fn listBarPolicies(self: *Catalog) ![]BarPolicy {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try cloneEntrySlice(self.alloc, BarPolicy, self.bar_policies.items);
    }

    pub fn listRollups(self: *Catalog) ![]RollupDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try cloneEntrySlice(self.alloc, RollupDefinition, self.rollups.items);
    }

    pub fn listSignals(self: *Catalog) ![]SignalDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try cloneEntrySlice(self.alloc, SignalDefinition, self.signals.items);
    }

    pub fn deleteRollup(self: *Catalog, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed_any = false;
        var idx: usize = 0;
        while (idx < self.rollups.items.len) {
            if (std.mem.eql(u8, self.rollups.items[idx].id, id)) {
                var removed = self.rollups.orderedRemove(idx);
                removed.deinit(self.alloc);
                removed_any = true;
                continue;
            }
            idx += 1;
        }
        if (removed_any and self.root != null) try self.rewriteLocked();
        return removed_any;
    }

    pub fn deleteSignal(self: *Catalog, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed_any = false;
        var idx: usize = 0;
        while (idx < self.signals.items.len) {
            if (std.mem.eql(u8, self.signals.items[idx].id, id)) {
                var removed = self.signals.orderedRemove(idx);
                removed.deinit(self.alloc);
                removed_any = true;
                continue;
            }
            idx += 1;
        }
        if (removed_any and self.root != null) try self.rewriteLocked();
        return removed_any;
    }

    pub fn latestBarPolicyById(self: *Catalog, id: []const u8) ?BarPolicy {
        self.mutex.lock();
        defer self.mutex.unlock();
        return cloneLatestBarPolicy(self.alloc, self.bar_policies.items, id) catch null;
    }

    pub fn registerSchema(self: *Catalog, input: MarketSchemaInput) !MarketSchema {
        self.mutex.lock();
        defer self.mutex.unlock();

        var next = try inputToSchema(self.alloc, input);
        errdefer next.deinit(self.alloc);
        for (self.schemas.items) |entry| {
            if (!std.mem.eql(u8, entry.metric, input.metric)) continue;
            if (!entry.eql(next)) return error.MarketSchemaConflict;
            return entry.clone(self.alloc);
        }
        try self.schemas.append(next);
        if (self.root != null) try self.rewriteLocked();
        return next.clone(self.alloc);
    }

    pub fn registerBarPolicy(self: *Catalog, input: BarPolicyInput) !BarPolicy {
        self.mutex.lock();
        defer self.mutex.unlock();

        const version = nextVersion(self.bar_policies.items, input.id);
        var candidate = try inputToBarPolicy(self.alloc, input, version);
        errdefer candidate.deinit(self.alloc);
        if (findMatchingBarPolicy(self.bar_policies.items, candidate)) |existing| {
            candidate.deinit(self.alloc);
            return existing.clone(self.alloc);
        }
        try self.bar_policies.append(candidate);
        if (self.root != null) try self.rewriteLocked();
        return candidate.clone(self.alloc);
    }

    pub fn registerRollup(self: *Catalog, input: RollupDefinitionInput) !RollupDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();

        const version = nextVersion(self.rollups.items, input.id);
        var candidate = try inputToRollup(self.alloc, input, version);
        errdefer candidate.deinit(self.alloc);
        if (findMatchingRollup(self.rollups.items, candidate)) |existing| {
            candidate.deinit(self.alloc);
            return existing.clone(self.alloc);
        }
        try self.rollups.append(candidate);
        if (self.root != null) try self.rewriteLocked();
        return candidate.clone(self.alloc);
    }

    pub fn registerSignal(self: *Catalog, input: SignalDefinitionInput) !SignalDefinition {
        self.mutex.lock();
        defer self.mutex.unlock();

        const version = nextVersion(self.signals.items, input.id);
        var candidate = try inputToSignal(self.alloc, input, version);
        errdefer candidate.deinit(self.alloc);
        if (findMatchingSignal(self.signals.items, candidate)) |existing| {
            candidate.deinit(self.alloc);
            return existing.clone(self.alloc);
        }
        try self.signals.append(candidate);
        if (self.root != null) try self.rewriteLocked();
        return candidate.clone(self.alloc);
    }

    fn loadFromJson(self: *Catalog, body: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMarketCatalog;
        const obj = parsed.value.object;

        if (obj.get("schemas")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                try self.schemas.append(try parseSchema(self.alloc, item));
            }
        }
        if (obj.get("bar_policies")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                try self.bar_policies.append(try parseBarPolicy(self.alloc, item));
            }
        }
        if (obj.get("rollups")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                try self.rollups.append(try parseRollup(self.alloc, item));
            }
        }
        if (obj.get("signals")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                try self.signals.append(try parseSignal(self.alloc, item));
            }
        }
    }

    fn ensureBuiltinSchemasLocked(self: *Catalog) !void {
        if (!hasSchema(self.schemas.items, "market.trade")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.trade",
                .ordered_columns = &.{ "price", "size" },
                .required_labels = &.{ "symbol", "venue" },
                .storage_mapping = .fanout_v1,
            }));
        }
        if (!hasSchema(self.schemas.items, "market.quote")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.quote",
                .ordered_columns = &.{ "bid", "ask", "bid_size", "ask_size" },
                .required_labels = &.{ "symbol", "venue" },
                .storage_mapping = .fanout_v1,
            }));
        }
        if (!hasSchema(self.schemas.items, "market.bar")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.bar",
                .ordered_columns = &.{ "open", "high", "low", "close", "volume", "vwap" },
                .required_labels = &.{ "symbol", "venue", "interval", "bar_policy_id" },
                .storage_mapping = .fanout_v1,
            }));
        }
    }

    fn rewriteLocked(self: *Catalog) !void {
        const root = self.root orelse return;
        const temp_name = "market_catalog.json.tmp";
        var file = try root.createFile(temp_name, .{ .truncate = true, .read = true });
        defer file.close();
        errdefer root.deleteFile(temp_name) catch {};

        var write_buf: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buf);
        const writer = &writer_state.interface;
        var jw = std.json.Stringify{ .writer = writer };
        try jw.beginObject();

        try jw.objectField("schemas");
        try jw.beginArray();
        for (self.schemas.items) |entry| try writeSchema(&jw, entry);
        try jw.endArray();

        try jw.objectField("bar_policies");
        try jw.beginArray();
        for (self.bar_policies.items) |entry| try writeBarPolicy(&jw, entry);
        try jw.endArray();

        try jw.objectField("rollups");
        try jw.beginArray();
        for (self.rollups.items) |entry| try writeRollup(&jw, entry);
        try jw.endArray();

        try jw.objectField("signals");
        try jw.beginArray();
        for (self.signals.items) |entry| try writeSignal(&jw, entry);
        try jw.endArray();

        try jw.endObject();
        try writer_state.end();
        if (self.fsync == .always) try file.sync();
        root.rename(temp_name, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                root.deleteFile(path) catch {};
                try root.rename(temp_name, path);
            },
            else => return err,
        };
    }
};

fn inputToSchema(alloc: std.mem.Allocator, input: MarketSchemaInput) !MarketSchema {
    return .{
        .metric = try alloc.dupe(u8, input.metric),
        .ordered_columns = try cloneConstStringArray(alloc, input.ordered_columns),
        .required_labels = try cloneConstStringArray(alloc, input.required_labels),
        .storage_mapping = input.storage_mapping,
    };
}

fn inputToBarPolicy(alloc: std.mem.Allocator, input: BarPolicyInput, version: u32) !BarPolicy {
    return .{
        .id = try alloc.dupe(u8, input.id),
        .version = version,
        .source_metric = try alloc.dupe(u8, input.source_metric),
        .interval_ns = input.interval_ns,
        .session_rule = try alloc.dupe(u8, input.session_rule),
        .no_trade_rule = try alloc.dupe(u8, input.no_trade_rule),
        .halt_rule = try alloc.dupe(u8, input.halt_rule),
        .correction_policy = try alloc.dupe(u8, input.correction_policy),
        .trade_filter = if (input.trade_filter) |value| try alloc.dupe(u8, value) else null,
    };
}

fn inputToRollup(alloc: std.mem.Allocator, input: RollupDefinitionInput, version: u32) !RollupDefinition {
    return .{
        .id = try alloc.dupe(u8, input.id),
        .version = version,
        .source_metric = try alloc.dupe(u8, input.source_metric),
        .target_metric = try alloc.dupe(u8, input.target_metric),
        .policy_id = try alloc.dupe(u8, input.policy_id),
        .transform_kind = input.transform_kind,
    };
}

fn inputToSignal(alloc: std.mem.Allocator, input: SignalDefinitionInput, version: u32) !SignalDefinition {
    return .{
        .id = try alloc.dupe(u8, input.id),
        .version = version,
        .input_metric = try alloc.dupe(u8, input.input_metric),
        .policy_id = if (input.policy_id) |value| try alloc.dupe(u8, value) else null,
        .expression_kind = input.expression_kind,
        .params_json = try canonicalJson(alloc, input.params_json),
        .emit_rule = try alloc.dupe(u8, input.emit_rule),
    };
}

fn parseSchema(alloc: std.mem.Allocator, value: std.json.Value) !MarketSchema {
    if (value != .object) return error.InvalidMarketCatalog;
    const obj = value.object;
    const metric_value = obj.get("metric") orelse return error.InvalidMarketCatalog;
    const columns_value = obj.get("ordered_columns") orelse return error.InvalidMarketCatalog;
    const labels_value = obj.get("required_labels") orelse return error.InvalidMarketCatalog;
    const storage_value = obj.get("storage_mapping") orelse return error.InvalidMarketCatalog;
    if (metric_value != .string or storage_value != .string) return error.InvalidMarketCatalog;
    return .{
        .metric = try alloc.dupe(u8, metric_value.string),
        .ordered_columns = try parseStringArray(alloc, columns_value),
        .required_labels = try parseStringArray(alloc, labels_value),
        .storage_mapping = StorageMapping.parse(storage_value.string) orelse return error.InvalidMarketCatalog,
    };
}

fn parseBarPolicy(alloc: std.mem.Allocator, value: std.json.Value) !BarPolicy {
    if (value != .object) return error.InvalidMarketCatalog;
    const obj = value.object;
    const id_value = obj.get("id") orelse return error.InvalidMarketCatalog;
    const version_value = obj.get("version") orelse return error.InvalidMarketCatalog;
    const source_value = obj.get("source_metric") orelse return error.InvalidMarketCatalog;
    const interval_value = obj.get("interval_ns") orelse return error.InvalidMarketCatalog;
    const session_value = obj.get("session_rule") orelse return error.InvalidMarketCatalog;
    const no_trade_value = obj.get("no_trade_rule") orelse return error.InvalidMarketCatalog;
    const halt_value = obj.get("halt_rule") orelse return error.InvalidMarketCatalog;
    const correction_value = obj.get("correction_policy") orelse return error.InvalidMarketCatalog;
    if (id_value != .string or source_value != .string or session_value != .string or no_trade_value != .string or halt_value != .string or correction_value != .string) return error.InvalidMarketCatalog;
    return .{
        .id = try alloc.dupe(u8, id_value.string),
        .version = try parseU32(version_value),
        .source_metric = try alloc.dupe(u8, source_value.string),
        .interval_ns = try parseI64(interval_value),
        .session_rule = try alloc.dupe(u8, session_value.string),
        .no_trade_rule = try alloc.dupe(u8, no_trade_value.string),
        .halt_rule = try alloc.dupe(u8, halt_value.string),
        .correction_policy = try alloc.dupe(u8, correction_value.string),
        .trade_filter = if (obj.get("trade_filter")) |trade_value|
            if (trade_value == .string) try alloc.dupe(u8, trade_value.string) else null
        else
            null,
    };
}

fn parseRollup(alloc: std.mem.Allocator, value: std.json.Value) !RollupDefinition {
    if (value != .object) return error.InvalidMarketCatalog;
    const obj = value.object;
    const id_value = obj.get("id") orelse return error.InvalidMarketCatalog;
    const version_value = obj.get("version") orelse return error.InvalidMarketCatalog;
    const source_value = obj.get("source_metric") orelse return error.InvalidMarketCatalog;
    const target_value = obj.get("target_metric") orelse return error.InvalidMarketCatalog;
    const policy_value = obj.get("policy_id") orelse return error.InvalidMarketCatalog;
    const kind_value = obj.get("transform_kind") orelse return error.InvalidMarketCatalog;
    if (id_value != .string or source_value != .string or target_value != .string or policy_value != .string or kind_value != .string) return error.InvalidMarketCatalog;
    return .{
        .id = try alloc.dupe(u8, id_value.string),
        .version = try parseU32(version_value),
        .source_metric = try alloc.dupe(u8, source_value.string),
        .target_metric = try alloc.dupe(u8, target_value.string),
        .policy_id = try alloc.dupe(u8, policy_value.string),
        .transform_kind = RollupTransformKind.parse(kind_value.string) orelse return error.InvalidMarketCatalog,
    };
}

fn parseSignal(alloc: std.mem.Allocator, value: std.json.Value) !SignalDefinition {
    if (value != .object) return error.InvalidMarketCatalog;
    const obj = value.object;
    const id_value = obj.get("id") orelse return error.InvalidMarketCatalog;
    const version_value = obj.get("version") orelse return error.InvalidMarketCatalog;
    const input_value = obj.get("input_metric") orelse return error.InvalidMarketCatalog;
    const expr_value = obj.get("expression_kind") orelse return error.InvalidMarketCatalog;
    const params_value = obj.get("params_json") orelse return error.InvalidMarketCatalog;
    const emit_value = obj.get("emit_rule") orelse return error.InvalidMarketCatalog;
    if (id_value != .string or input_value != .string or expr_value != .string or params_value != .string or emit_value != .string) return error.InvalidMarketCatalog;
    return .{
        .id = try alloc.dupe(u8, id_value.string),
        .version = try parseU32(version_value),
        .input_metric = try alloc.dupe(u8, input_value.string),
        .policy_id = if (obj.get("policy_id")) |policy_value|
            if (policy_value == .string) try alloc.dupe(u8, policy_value.string) else null
        else
            null,
        .expression_kind = SignalExpressionKind.parse(expr_value.string) orelse return error.InvalidMarketCatalog,
        .params_json = try alloc.dupe(u8, params_value.string),
        .emit_rule = try alloc.dupe(u8, emit_value.string),
    };
}

pub fn writeSchema(jw: *std.json.Stringify, entry: MarketSchema) !void {
    try jw.beginObject();
    try jw.objectField("metric");
    try jw.write(entry.metric);
    try jw.objectField("ordered_columns");
    try writeStringArray(jw, entry.ordered_columns);
    try jw.objectField("required_labels");
    try writeStringArray(jw, entry.required_labels);
    try jw.objectField("storage_mapping");
    try jw.write(entry.storage_mapping.text());
    try jw.endObject();
}

pub fn writeBarPolicy(jw: *std.json.Stringify, entry: BarPolicy) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("version");
    try jw.write(entry.version);
    try jw.objectField("source_metric");
    try jw.write(entry.source_metric);
    try jw.objectField("interval_ns");
    try jw.write(entry.interval_ns);
    try jw.objectField("session_rule");
    try jw.write(entry.session_rule);
    try jw.objectField("no_trade_rule");
    try jw.write(entry.no_trade_rule);
    try jw.objectField("halt_rule");
    try jw.write(entry.halt_rule);
    try jw.objectField("correction_policy");
    try jw.write(entry.correction_policy);
    if (entry.trade_filter) |value| {
        try jw.objectField("trade_filter");
        try jw.write(value);
    }
    try jw.endObject();
}

pub fn writeRollup(jw: *std.json.Stringify, entry: RollupDefinition) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("version");
    try jw.write(entry.version);
    try jw.objectField("source_metric");
    try jw.write(entry.source_metric);
    try jw.objectField("target_metric");
    try jw.write(entry.target_metric);
    try jw.objectField("policy_id");
    try jw.write(entry.policy_id);
    try jw.objectField("transform_kind");
    try jw.write(entry.transform_kind.text());
    try jw.endObject();
}

pub fn writeSignal(jw: *std.json.Stringify, entry: SignalDefinition) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("version");
    try jw.write(entry.version);
    try jw.objectField("input_metric");
    try jw.write(entry.input_metric);
    if (entry.policy_id) |value| {
        try jw.objectField("policy_id");
        try jw.write(value);
    }
    try jw.objectField("expression_kind");
    try jw.write(entry.expression_kind.text());
    try jw.objectField("params_json");
    try jw.write(entry.params_json);
    try jw.objectField("emit_rule");
    try jw.write(entry.emit_rule);
    try jw.endObject();
}

fn hasSchema(entries: []const MarketSchema, metric: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.metric, metric)) return true;
    }
    return false;
}

fn nextVersion(entries: anytype, id: []const u8) u32 {
    var next: u32 = 1;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        if (entry.version >= next) next = entry.version + 1;
    }
    return next;
}

fn findMatchingBarPolicy(entries: []const BarPolicy, candidate: BarPolicy) ?BarPolicy {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.id, candidate.id)) continue;
        if (std.mem.eql(u8, entry.source_metric, candidate.source_metric) and
            entry.interval_ns == candidate.interval_ns and
            std.mem.eql(u8, entry.session_rule, candidate.session_rule) and
            std.mem.eql(u8, entry.no_trade_rule, candidate.no_trade_rule) and
            std.mem.eql(u8, entry.halt_rule, candidate.halt_rule) and
            std.mem.eql(u8, entry.correction_policy, candidate.correction_policy) and
            optionalStringEql(entry.trade_filter, candidate.trade_filter))
        {
            return entry;
        }
    }
    return null;
}

fn cloneLatestBarPolicy(alloc: std.mem.Allocator, entries: []const BarPolicy, id: []const u8) !?BarPolicy {
    var best: ?BarPolicy = null;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.id, id)) continue;
        if (best == null or entry.version > best.?.version) best = entry;
    }
    if (best) |entry| return try entry.clone(alloc);
    return null;
}

fn findMatchingRollup(entries: []const RollupDefinition, candidate: RollupDefinition) ?RollupDefinition {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, candidate.id) and
            std.mem.eql(u8, entry.source_metric, candidate.source_metric) and
            std.mem.eql(u8, entry.target_metric, candidate.target_metric) and
            std.mem.eql(u8, entry.policy_id, candidate.policy_id) and
            entry.transform_kind == candidate.transform_kind)
        {
            return entry;
        }
    }
    return null;
}

fn findMatchingSignal(entries: []const SignalDefinition, candidate: SignalDefinition) ?SignalDefinition {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, candidate.id) and
            std.mem.eql(u8, entry.input_metric, candidate.input_metric) and
            optionalStringEql(entry.policy_id, candidate.policy_id) and
            entry.expression_kind == candidate.expression_kind and
            std.mem.eql(u8, entry.params_json, candidate.params_json) and
            std.mem.eql(u8, entry.emit_rule, candidate.emit_rule))
        {
            return entry;
        }
    }
    return null;
}

fn parseStringArray(alloc: std.mem.Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidMarketCatalog;
    const result = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(result);
    for (value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidMarketCatalog;
        result[idx] = try alloc.dupe(u8, item.string);
    }
    return result;
}

fn writeStringArray(jw: *std.json.Stringify, items: [][]u8) !void {
    try jw.beginArray();
    for (items) |item| try jw.write(item);
    try jw.endArray();
}

fn cloneStringArray(alloc: std.mem.Allocator, items: [][]u8) ![][]u8 {
    const result = try alloc.alloc([]u8, items.len);
    errdefer alloc.free(result);
    for (items, 0..) |item, idx| result[idx] = try alloc.dupe(u8, item);
    return result;
}

fn cloneConstStringArray(alloc: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const result = try alloc.alloc([]u8, items.len);
    errdefer alloc.free(result);
    for (items, 0..) |item, idx| result[idx] = try alloc.dupe(u8, item);
    return result;
}

fn freeStringArray(alloc: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn stringArrayEql(lhs: [][]u8, rhs: [][]u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

fn cloneEntrySlice(alloc: std.mem.Allocator, comptime T: type, entries: []const T) ![]T {
    const out = try alloc.alloc(T, entries.len);
    errdefer alloc.free(out);
    for (entries, 0..) |entry, idx| out[idx] = try entry.clone(alloc);
    return out;
}

fn optionalStringEql(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    return std.mem.eql(u8, lhs.?, rhs.?);
}

fn parseU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |int| @intCast(int),
        .number_string => |digits| try std.fmt.parseInt(u32, digits, 10),
        else => error.InvalidMarketCatalog,
    };
}

fn parseI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |int| int,
        .number_string => |digits| try std.fmt.parseInt(i64, digits, 10),
        else => error.InvalidMarketCatalog,
    };
}

fn canonicalJson(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return alloc.dupe(u8, "{}");
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
    defer parsed.deinit();

    var buffer = std.array_list.Managed(u8).init(alloc);
    errdefer buffer.deinit();
    var writer = buffer.writer();
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    var iface = &adapter.new_interface;
    var jw = std.json.Stringify{ .writer = iface };
    try writeCanonicalValue(alloc, parsed.value, &jw);
    try iface.flush();
    if (adapter.err) |err| return err;
    return try buffer.toOwnedSlice();
}

fn writeCanonicalValue(alloc: std.mem.Allocator, value: std.json.Value, jw: *std.json.Stringify) !void {
    switch (value) {
        .null => try jw.write(null),
        .bool => |b| try jw.write(b),
        .integer => |i| try jw.write(i),
        .float => |f| try jw.write(f),
        .number_string => |n| try jw.write(n),
        .string => |s| try jw.write(s),
        .array => |items| {
            try jw.beginArray();
            for (items.items) |item| try writeCanonicalValue(alloc, item, jw);
            try jw.endArray();
        },
        .object => |obj| {
            var keys = try alloc.alloc([]const u8, obj.count());
            defer alloc.free(keys);
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) keys[idx] = entry.key_ptr.*;
            std.sort.block([]const u8, keys, {}, struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.lessThan(u8, lhs, rhs);
                }
            }.lessThan);
            try jw.beginObject();
            for (keys) |key| {
                try jw.objectField(key);
                try writeCanonicalValue(alloc, obj.get(key).?, jw);
            }
            try jw.endObject();
        },
    }
}

test "market catalog loads builtin schemas" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();

    const schemas = try catalog.listSchemas();
    defer {
        for (schemas) |*entry| entry.deinit(alloc);
        alloc.free(schemas);
    }
    try std.testing.expect(schemas.len >= 3);
}

test "registering same bar policy payload reuses version" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();

    const first = try catalog.registerBarPolicy(.{
        .id = "regular-hours-1m",
        .source_metric = "market.trade",
        .interval_ns = 60 * std.time.ns_per_s,
        .session_rule = "regular_hours",
        .no_trade_rule = "carry_forward_none",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer {
        var copy = first;
        copy.deinit(alloc);
    }
    const second = try catalog.registerBarPolicy(.{
        .id = "regular-hours-1m",
        .source_metric = "market.trade",
        .interval_ns = 60 * std.time.ns_per_s,
        .session_rule = "regular_hours",
        .no_trade_rule = "carry_forward_none",
        .halt_rule = "skip_halts",
        .correction_policy = "append_only",
        .trade_filter = null,
    });
    defer {
        var copy = second;
        copy.deinit(alloc);
    }
    try std.testing.expectEqual(@as(u32, 1), first.version);
    try std.testing.expectEqual(@as(u32, 1), second.version);
}

test "market catalog persists rollup and signal deletions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
        defer catalog.deinit();

        var policy = try catalog.registerBarPolicy(.{
            .id = "regular-hours-1m",
            .source_metric = "market.trade",
            .interval_ns = 60 * std.time.ns_per_s,
            .session_rule = "regular_hours",
            .no_trade_rule = "carry_forward_none",
            .halt_rule = "skip_halts",
            .correction_policy = "append_only",
            .trade_filter = null,
        });
        defer policy.deinit(alloc);

        var rollup = try catalog.registerRollup(.{
            .id = "bars-1m",
            .source_metric = "market.trade",
            .target_metric = "market.bar",
            .policy_id = "regular-hours-1m",
            .transform_kind = .trade_to_bar,
        });
        defer rollup.deinit(alloc);

        var signal = try catalog.registerSignal(.{
            .id = "ema-fast",
            .input_metric = "market.bar",
            .policy_id = "regular-hours-1m",
            .expression_kind = .ema,
            .params_json = "{\"period\":12}",
            .emit_rule = "on_close",
        });
        defer signal.deinit(alloc);

        try std.testing.expect(try catalog.deleteRollup("bars-1m"));
        try std.testing.expect(try catalog.deleteSignal("ema-fast"));
        try std.testing.expect(!(try catalog.deleteRollup("bars-1m")));
        try std.testing.expect(!(try catalog.deleteSignal("ema-fast")));
    }

    {
        var reloaded = try Catalog.loadOrInit(alloc, tmp.dir, .none);
        defer reloaded.deinit();

        const rollups = try reloaded.listRollups();
        defer {
            for (rollups) |*entry| entry.deinit(alloc);
            alloc.free(rollups);
        }
        try std.testing.expectEqual(@as(usize, 0), rollups.len);

        const signals = try reloaded.listSignals();
        defer {
            for (signals) |*entry| entry.deinit(alloc);
            alloc.free(signals);
        }
        try std.testing.expectEqual(@as(usize, 0), signals.len);
    }
}
