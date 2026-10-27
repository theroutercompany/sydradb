const std = @import("std");
const cfg = @import("../config.zig");
const market_identity = @import("market_identity.zig");

pub const path = "market_catalog.json";

pub const StorageMapping = enum {
    fanout_v1,
    native_v1,

    pub fn parse(input_text: []const u8) ?StorageMapping {
        if (std.ascii.eqlIgnoreCase(input_text, "fanout_v1")) return .fanout_v1;
        if (std.ascii.eqlIgnoreCase(input_text, "native_v1")) return .native_v1;
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
        const metric = try alloc.dupe(u8, self.metric);
        errdefer alloc.free(metric);
        const ordered_columns = try cloneStringArray(alloc, self.ordered_columns);
        errdefer freeStringArray(alloc, ordered_columns);
        return .{
            .metric = metric,
            .ordered_columns = ordered_columns,
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

    pub fn digest(self: MarketSchema) market_identity.SchemaDigest {
        return market_identity.schemaDigest(
            self.metric,
            self.ordered_columns,
            self.required_labels,
            self.storage_mapping.text(),
        );
    }
};

pub const MarketSchemaInput = struct {
    metric: []const u8,
    ordered_columns: []const []const u8,
    required_labels: []const []const u8,
    storage_mapping: StorageMapping = .fanout_v1,
};

pub const MarketSeriesIdentity = struct {
    series_id: market_identity.MarketSeriesId,
    schema_digest: market_identity.SchemaDigest,
    metric: []u8,
    canonical_labels: []u8,

    pub fn clone(self: MarketSeriesIdentity, alloc: std.mem.Allocator) !MarketSeriesIdentity {
        const metric = try alloc.dupe(u8, self.metric);
        errdefer alloc.free(metric);
        return .{
            .series_id = self.series_id,
            .schema_digest = self.schema_digest,
            .metric = metric,
            .canonical_labels = try alloc.dupe(u8, self.canonical_labels),
        };
    }

    pub fn deinit(self: *MarketSeriesIdentity, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        self.* = undefined;
    }

    pub fn sameIdentity(self: MarketSeriesIdentity, metric: []const u8, canonical_labels: []const u8) bool {
        return std.mem.eql(u8, self.metric, metric) and
            std.mem.eql(u8, self.canonical_labels, canonical_labels);
    }
};

pub const MarketSeriesRegistrationInput = struct {
    series_id: market_identity.MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
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
    market_series: ?[]MarketSeriesIdentity = null,
    bar_policies: []BarPolicy,
    rollups: []RollupDefinition,
    signals: []SignalDefinition,

    pub fn empty(alloc: std.mem.Allocator) !Snapshot {
        return .{
            .schemas = try alloc.alloc(MarketSchema, 0),
            .market_series = try alloc.alloc(MarketSeriesIdentity, 0),
            .bar_policies = try alloc.alloc(BarPolicy, 0),
            .rollups = try alloc.alloc(RollupDefinition, 0),
            .signals = try alloc.alloc(SignalDefinition, 0),
        };
    }

    pub fn clone(self: Snapshot, alloc: std.mem.Allocator) !Snapshot {
        var schemas = try alloc.alloc(MarketSchema, self.schemas.len);
        errdefer alloc.free(schemas);
        for (self.schemas, 0..) |entry, idx| schemas[idx] = try entry.clone(alloc);

        const market_series = if (self.market_series) |entries|
            try cloneEntrySlice(alloc, MarketSeriesIdentity, entries)
        else
            null;
        errdefer if (market_series) |entries| {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        };

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
            .market_series = market_series,
            .bar_policies = bar_policies,
            .rollups = rollups,
            .signals = signals,
        };
    }

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.schemas) |*entry| entry.deinit(alloc);
        alloc.free(self.schemas);
        if (self.market_series) |entries| {
            for (entries) |*entry| entry.deinit(alloc);
            alloc.free(entries);
        }
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
    market_series: std.array_list.Managed(MarketSeriesIdentity),
    market_series_by_metric: std.StringHashMap(std.ArrayListUnmanaged(usize)),
    bar_policies: std.array_list.Managed(BarPolicy),
    rollups: std.array_list.Managed(RollupDefinition),
    signals: std.array_list.Managed(SignalDefinition),

    pub fn initEmpty(alloc: std.mem.Allocator, fsync: cfg.FsyncPolicy) Catalog {
        return .{
            .alloc = alloc,
            .fsync = fsync,
            .schemas = std.array_list.Managed(MarketSchema).init(alloc),
            .market_series = std.array_list.Managed(MarketSeriesIdentity).init(alloc),
            .market_series_by_metric = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(alloc),
            .bar_policies = std.array_list.Managed(BarPolicy).init(alloc),
            .rollups = std.array_list.Managed(RollupDefinition).init(alloc),
            .signals = std.array_list.Managed(SignalDefinition).init(alloc),
        };
    }

    pub const LoadOrInitOptions = struct {
        /// Applied only when the catalog file does not exist. A present
        /// catalog always preserves stored mappings and fills any missing
        /// built-ins as fanout-compatible schemas.
        new_catalog_builtin_mapping: StorageMapping = .fanout_v1,
    };

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir, fsync: cfg.FsyncPolicy) !Catalog {
        return try loadOrInitWithOptions(alloc, data_dir, fsync, .{});
    }

    pub fn loadOrInitWithOptions(
        alloc: std.mem.Allocator,
        data_dir: std.fs.Dir,
        fsync: cfg.FsyncPolicy,
        options: LoadOrInitOptions,
    ) !Catalog {
        const root = try data_dir.openDir(".", .{ .iterate = true });
        var catalog = Catalog.initEmpty(alloc, fsync);
        catalog.root = root;
        errdefer catalog.deinit();

        const body = catalog.root.?.readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (body) |buf| alloc.free(buf);

        if (body) |buf| try catalog.loadFromJson(buf);
        try catalog.ensureBuiltinSchemasLocked(if (body == null)
            options.new_catalog_builtin_mapping
        else
            .fanout_v1);
        if (catalog.root != null) try catalog.rewriteLocked();
        return catalog;
    }

    pub fn initFromSnapshot(
        alloc: std.mem.Allocator,
        data_dir: std.fs.Dir,
        fsync: cfg.FsyncPolicy,
        snapshot: Snapshot,
    ) !Catalog {
        const root = try data_dir.openDir(".", .{ .iterate = true });
        var catalog = Catalog.initEmpty(alloc, fsync);
        catalog.root = root;
        errdefer catalog.deinit();

        for (snapshot.schemas) |entry| {
            market_identity.validateSchemaShape(
                entry.metric,
                entry.ordered_columns,
                entry.required_labels,
            ) catch return error.InvalidMarketCatalog;
            if (hasSchema(catalog.schemas.items, entry.metric)) {
                return error.InvalidMarketCatalog;
            }
            try catalog.schemas.append(try entry.clone(alloc));
        }
        if (snapshot.market_series) |entries| {
            for (entries) |entry| {
                if (entry.series_id != market_identity.seriesId(entry.metric, entry.canonical_labels)) {
                    return error.InvalidMarketCatalog;
                }
                market_identity.validateCanonicalLabelsObject(
                    alloc,
                    entry.canonical_labels,
                ) catch return error.InvalidMarketCatalog;
                const schema = findSchema(catalog.schemas.items, entry.metric) orelse
                    return error.InvalidMarketCatalog;
                const expected_digest = schema.digest();
                if (!std.mem.eql(u8, &entry.schema_digest, &expected_digest)) {
                    return error.InvalidMarketCatalog;
                }
                market_identity.validateRequiredLabels(
                    alloc,
                    entry.canonical_labels,
                    schema.required_labels,
                ) catch return error.InvalidMarketCatalog;
                if (try resolveMarketSeriesRegistration(
                    catalog.market_series.items,
                    entry.series_id,
                    entry.metric,
                    entry.canonical_labels,
                    entry.schema_digest,
                )) |_| return error.InvalidMarketCatalog;
                const metric_indexes = try catalog.prepareMarketSeriesMetricIndexLocked(entry.metric, 1);
                try catalog.market_series.append(try entry.clone(alloc));
                metric_indexes.appendAssumeCapacity(catalog.market_series.items.len - 1);
            }
        }
        for (snapshot.bar_policies) |entry| try catalog.bar_policies.append(try entry.clone(alloc));
        for (snapshot.rollups) |entry| try catalog.rollups.append(try entry.clone(alloc));
        for (snapshot.signals) |entry| try catalog.signals.append(try entry.clone(alloc));
        try catalog.ensureBuiltinSchemasLocked(.fanout_v1);
        return catalog;
    }

    pub fn deinit(self: *Catalog) void {
        for (self.schemas.items) |*entry| entry.deinit(self.alloc);
        self.schemas.deinit();
        for (self.market_series.items) |*entry| entry.deinit(self.alloc);
        self.market_series.deinit();
        var metric_it = self.market_series_by_metric.iterator();
        while (metric_it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.alloc);
        }
        self.market_series_by_metric.deinit();
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
            .market_series = try cloneEntrySlice(self.alloc, MarketSeriesIdentity, self.market_series.items),
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

    pub fn registerMarketSeries(
        self: *Catalog,
        metric: []const u8,
        labels_json: []const u8,
    ) !MarketSeriesIdentity {
        const canonical_labels = try market_identity.canonicalizeLabels(self.alloc, labels_json);
        defer self.alloc.free(canonical_labels);
        return try self.registerCanonicalMarketSeries(
            market_identity.seriesId(metric, canonical_labels),
            metric,
            canonical_labels,
        );
    }

    pub fn registerMarketSeriesWithId(
        self: *Catalog,
        series_id: market_identity.MarketSeriesId,
        metric: []const u8,
        labels_json: []const u8,
    ) !MarketSeriesIdentity {
        const canonical_labels = try market_identity.canonicalizeLabels(self.alloc, labels_json);
        defer self.alloc.free(canonical_labels);
        if (series_id != market_identity.seriesId(metric, canonical_labels)) {
            return error.MarketSeriesIdMismatch;
        }
        return try self.registerCanonicalMarketSeries(series_id, metric, canonical_labels);
    }

    pub fn registerCanonicalMarketSeriesBatch(
        self: *Catalog,
        inputs: []const MarketSeriesRegistrationInput,
    ) ![]MarketSeriesIdentity {
        if (inputs.len == 0) return try self.alloc.alloc(MarketSeriesIdentity, 0);

        self.mutex.lock();
        defer self.mutex.unlock();

        var results = try self.alloc.alloc(MarketSeriesIdentity, inputs.len);
        var results_len: usize = 0;
        errdefer {
            for (results[0..results_len]) |*result| result.deinit(self.alloc);
            self.alloc.free(results);
        }

        var staged = std.array_list.Managed(MarketSeriesIdentity).init(self.alloc);
        defer {
            for (staged.items) |*entry| entry.deinit(self.alloc);
            staged.deinit();
        }
        try staged.ensureTotalCapacity(inputs.len);

        for (inputs, 0..) |input, idx| {
            if (input.series_id != market_identity.seriesId(input.metric, input.canonical_labels)) {
                return error.MarketSeriesIdMismatch;
            }
            market_identity.validateCanonicalLabelsObject(
                self.alloc,
                input.canonical_labels,
            ) catch return error.InvalidMarketLabels;

            const schema = findSchema(self.schemas.items, input.metric) orelse return error.UnknownMarketSchema;
            try market_identity.validateRequiredLabels(
                self.alloc,
                input.canonical_labels,
                schema.required_labels,
            );
            const schema_digest = schema.digest();

            if (try resolveMarketSeriesRegistration(
                self.market_series.items,
                input.series_id,
                input.metric,
                input.canonical_labels,
                schema_digest,
            )) |existing| {
                results[idx] = try existing.clone(self.alloc);
                results_len += 1;
                continue;
            }

            if (try resolveMarketSeriesRegistration(
                staged.items,
                input.series_id,
                input.metric,
                input.canonical_labels,
                schema_digest,
            )) |existing| {
                results[idx] = try existing.clone(self.alloc);
                results_len += 1;
                continue;
            }

            const owned_metric = try self.alloc.dupe(u8, input.metric);
            var owned_metric_owned = true;
            errdefer if (owned_metric_owned) self.alloc.free(owned_metric);
            const owned_labels = try self.alloc.dupe(u8, input.canonical_labels);
            var owned_labels_owned = true;
            errdefer if (owned_labels_owned) self.alloc.free(owned_labels);

            var candidate = MarketSeriesIdentity{
                .series_id = input.series_id,
                .schema_digest = schema_digest,
                .metric = owned_metric,
                .canonical_labels = owned_labels,
            };
            owned_metric_owned = false;
            owned_labels_owned = false;
            var candidate_owned = true;
            errdefer if (candidate_owned) candidate.deinit(self.alloc);

            results[idx] = try candidate.clone(self.alloc);
            results_len += 1;
            staged.appendAssumeCapacity(candidate);
            candidate_owned = false;
        }

        try self.market_series.ensureUnusedCapacity(staged.items.len);
        for (staged.items, 0..) |entry, staged_idx| {
            var seen = false;
            for (staged.items[0..staged_idx]) |prior| {
                if (std.mem.eql(u8, prior.metric, entry.metric)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            var metric_count: usize = 0;
            for (staged.items[staged_idx..]) |candidate| {
                if (std.mem.eql(u8, candidate.metric, entry.metric)) {
                    metric_count += 1;
                }
            }
            _ = try self.prepareMarketSeriesMetricIndexLocked(entry.metric, metric_count);
        }
        const appended_start = self.market_series.items.len;
        for (staged.items) |entry| {
            self.market_series.appendAssumeCapacity(entry);
            self.market_series_by_metric.getPtr(entry.metric).?.appendAssumeCapacity(
                self.market_series.items.len - 1,
            );
        }
        staged.clearRetainingCapacity();

        if (self.root != null) {
            self.rewriteLocked() catch |err| {
                while (self.market_series.items.len > appended_start) {
                    var removed = self.market_series.pop().?;
                    const indexes = self.market_series_by_metric.getPtr(removed.metric).?;
                    std.debug.assert(indexes.items[indexes.items.len - 1] == self.market_series.items.len);
                    _ = indexes.pop();
                    removed.deinit(self.alloc);
                }
                return err;
            };
        }

        return results;
    }

    pub fn getMarketSeries(
        self: *Catalog,
        series_id: market_identity.MarketSeriesId,
    ) ?MarketSeriesIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.market_series.items) |entry| {
            if (entry.series_id == series_id) return entry.clone(self.alloc) catch return null;
        }
        return null;
    }

    pub fn listMarketSeries(self: *Catalog) ![]MarketSeriesIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        return try cloneEntrySlice(self.alloc, MarketSeriesIdentity, self.market_series.items);
    }

    pub fn listMarketSeriesForMetric(
        self: *Catalog,
        metric: []const u8,
    ) ![]MarketSeriesIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();
        const indexes = self.market_series_by_metric.get(metric) orelse
            return try self.alloc.alloc(MarketSeriesIdentity, 0);
        const entries = try self.alloc.alloc(MarketSeriesIdentity, indexes.items.len);
        errdefer self.alloc.free(entries);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |*entry| entry.deinit(self.alloc);
        for (indexes.items, 0..) |index, result_idx| {
            entries[result_idx] = try self.market_series.items[index].clone(self.alloc);
            initialized += 1;
        }
        return entries;
    }

    fn prepareMarketSeriesMetricIndexLocked(
        self: *Catalog,
        metric: []const u8,
        additional: usize,
    ) !*std.ArrayListUnmanaged(usize) {
        if (self.market_series_by_metric.getPtr(metric)) |indexes| {
            try indexes.ensureUnusedCapacity(self.alloc, additional);
            return indexes;
        }
        const owned_metric = try self.alloc.dupe(u8, metric);
        errdefer self.alloc.free(owned_metric);
        var indexes: std.ArrayListUnmanaged(usize) = .{};
        errdefer indexes.deinit(self.alloc);
        try indexes.ensureUnusedCapacity(self.alloc, additional);
        try self.market_series_by_metric.put(owned_metric, indexes);
        return self.market_series_by_metric.getPtr(owned_metric).?;
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

    /// Promote every stored schema mapping and registered-series digest in one
    /// catalog rewrite. The operator migration state provides crash recovery
    /// across this rewrite and the repository-format update.
    pub fn promoteAllSchemasToNative(self: *Catalog) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var promoted: usize = 0;
        for (self.schemas.items) |*schema| {
            if (schema.storage_mapping == .native_v1) continue;
            schema.storage_mapping = .native_v1;
            promoted += 1;
        }
        for (self.market_series.items) |*entry| {
            const schema = findSchema(self.schemas.items, entry.metric) orelse
                return error.UnknownMarketSchema;
            entry.schema_digest = schema.digest();
        }
        if (promoted == 0 or self.root == null) return promoted;

        const previous_fsync = self.fsync;
        self.fsync = .always;
        defer self.fsync = previous_fsync;
        try self.rewriteLocked();
        var root = self.root.?;
        try syncDir(&root);
        return promoted;
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
        var next_owned = true;
        errdefer if (next_owned) next.deinit(self.alloc);
        for (self.schemas.items) |entry| {
            if (!std.mem.eql(u8, entry.metric, input.metric)) continue;
            if (!entry.eql(next)) return error.MarketSchemaConflict;
            next.deinit(self.alloc);
            next_owned = false;
            return entry.clone(self.alloc);
        }
        try self.schemas.append(next);
        next_owned = false;
        if (self.root != null) {
            self.rewriteLocked() catch |err| {
                var removed = self.schemas.pop().?;
                removed.deinit(self.alloc);
                return err;
            };
        }
        return next.clone(self.alloc);
    }

    fn registerCanonicalMarketSeries(
        self: *Catalog,
        series_id: market_identity.MarketSeriesId,
        metric: []const u8,
        canonical_labels: []const u8,
    ) !MarketSeriesIdentity {
        self.mutex.lock();
        defer self.mutex.unlock();

        const schema = findSchema(self.schemas.items, metric) orelse return error.UnknownMarketSchema;
        try market_identity.validateRequiredLabels(
            self.alloc,
            canonical_labels,
            schema.required_labels,
        );
        const owned_metric = try self.alloc.dupe(u8, metric);
        const owned_labels = self.alloc.dupe(u8, canonical_labels) catch |err| {
            self.alloc.free(owned_metric);
            return err;
        };
        var candidate = MarketSeriesIdentity{
            .series_id = series_id,
            .schema_digest = schema.digest(),
            .metric = owned_metric,
            .canonical_labels = owned_labels,
        };
        var candidate_owned = true;
        errdefer if (candidate_owned) candidate.deinit(self.alloc);

        if (try resolveMarketSeriesRegistration(
            self.market_series.items,
            series_id,
            metric,
            canonical_labels,
            candidate.schema_digest,
        )) |existing| {
            candidate.deinit(self.alloc);
            candidate_owned = false;
            return existing.clone(self.alloc);
        }
        const metric_indexes = try self.prepareMarketSeriesMetricIndexLocked(candidate.metric, 1);
        try self.market_series.append(candidate);
        candidate_owned = false;
        if (self.root != null) {
            self.rewriteLocked() catch |err| {
                var removed = self.market_series.pop().?;
                removed.deinit(self.alloc);
                return err;
            };
        }
        metric_indexes.appendAssumeCapacity(self.market_series.items.len - 1);
        return candidate.clone(self.alloc);
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
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.alloc,
            body,
            .{},
        ) catch return error.InvalidMarketCatalog;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMarketCatalog;
        const obj = parsed.value.object;

        if (obj.get("schemas")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                var schema = try parseSchema(self.alloc, item);
                errdefer schema.deinit(self.alloc);
                if (hasSchema(self.schemas.items, schema.metric)) {
                    return error.InvalidMarketCatalog;
                }
                try self.schemas.append(schema);
            }
        }
        if (obj.get("market_series")) |value| {
            if (value != .array) return error.InvalidMarketCatalog;
            for (value.array.items) |item| {
                var entry = try parseMarketSeriesIdentity(self.alloc, item);
                errdefer entry.deinit(self.alloc);
                if (entry.series_id != market_identity.seriesId(entry.metric, entry.canonical_labels)) {
                    return error.InvalidMarketCatalog;
                }
                const schema = findSchema(self.schemas.items, entry.metric) orelse return error.InvalidMarketCatalog;
                const expected_digest = schema.digest();
                if (!std.mem.eql(u8, &entry.schema_digest, &expected_digest)) {
                    return error.InvalidMarketCatalog;
                }
                market_identity.validateRequiredLabels(
                    self.alloc,
                    entry.canonical_labels,
                    schema.required_labels,
                ) catch return error.InvalidMarketCatalog;
                if (try resolveMarketSeriesRegistration(
                    self.market_series.items,
                    entry.series_id,
                    entry.metric,
                    entry.canonical_labels,
                    entry.schema_digest,
                )) |_| {
                    entry.deinit(self.alloc);
                    continue;
                }
                const metric_indexes = try self.prepareMarketSeriesMetricIndexLocked(entry.metric, 1);
                try self.market_series.append(entry);
                metric_indexes.appendAssumeCapacity(self.market_series.items.len - 1);
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

    fn ensureBuiltinSchemasLocked(self: *Catalog, storage_mapping: StorageMapping) !void {
        if (!hasSchema(self.schemas.items, "market.trade")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.trade",
                .ordered_columns = &.{ "price", "size" },
                .required_labels = &.{ "symbol", "venue" },
                .storage_mapping = storage_mapping,
            }));
        }
        if (!hasSchema(self.schemas.items, "market.quote")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.quote",
                .ordered_columns = &.{ "bid", "ask", "bid_size", "ask_size" },
                .required_labels = &.{ "symbol", "venue" },
                .storage_mapping = storage_mapping,
            }));
        }
        if (!hasSchema(self.schemas.items, "market.bar")) {
            try self.schemas.append(try inputToSchema(self.alloc, .{
                .metric = "market.bar",
                .ordered_columns = &.{ "open", "high", "low", "close", "volume", "vwap" },
                .required_labels = &.{ "symbol", "venue", "interval", "bar_policy_id" },
                .storage_mapping = storage_mapping,
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

        try jw.objectField("market_series");
        try jw.beginArray();
        for (self.market_series.items) |entry| try writeMarketSeriesIdentity(&jw, entry);
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

fn syncDir(dir: *std.fs.Dir) !void {
    if (@hasDecl(std.fs.Dir, "sync")) try dir.sync();
}

fn inputToSchema(alloc: std.mem.Allocator, input: MarketSchemaInput) !MarketSchema {
    try market_identity.validateSchemaShape(
        input.metric,
        input.ordered_columns,
        input.required_labels,
    );
    const metric = try alloc.dupe(u8, input.metric);
    errdefer alloc.free(metric);
    const ordered_columns = try cloneConstStringArray(alloc, input.ordered_columns);
    errdefer freeStringArray(alloc, ordered_columns);
    return .{
        .metric = metric,
        .ordered_columns = ordered_columns,
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
    if (metric_value != .string) return error.InvalidMarketCatalog;
    const storage_mapping = if (obj.get("storage_mapping")) |storage_value| blk: {
        if (storage_value != .string) return error.InvalidMarketCatalog;
        break :blk StorageMapping.parse(storage_value.string) orelse return error.InvalidMarketCatalog;
    } else .fanout_v1;
    const ordered_columns = try parseStringArray(alloc, columns_value);
    errdefer freeStringArray(alloc, ordered_columns);
    const required_labels = try parseStringArray(alloc, labels_value);
    errdefer freeStringArray(alloc, required_labels);
    market_identity.validateSchemaShape(
        metric_value.string,
        ordered_columns,
        required_labels,
    ) catch return error.InvalidMarketCatalog;
    return .{
        .metric = try alloc.dupe(u8, metric_value.string),
        .ordered_columns = ordered_columns,
        .required_labels = required_labels,
        .storage_mapping = storage_mapping,
    };
}

fn parseMarketSeriesIdentity(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) !MarketSeriesIdentity {
    if (value != .object) return error.InvalidMarketCatalog;
    const obj = value.object;
    const id_value = obj.get("series_id") orelse return error.InvalidMarketCatalog;
    const digest_value = obj.get("schema_digest") orelse return error.InvalidMarketCatalog;
    const metric_value = obj.get("metric") orelse return error.InvalidMarketCatalog;
    const labels_value = obj.get("canonical_labels") orelse return error.InvalidMarketCatalog;
    if (digest_value != .string or metric_value != .string or labels_value != .string) {
        return error.InvalidMarketCatalog;
    }

    const canonical_labels = market_identity.canonicalizeLabels(
        alloc,
        labels_value.string,
    ) catch return error.InvalidMarketCatalog;
    errdefer alloc.free(canonical_labels);
    if (!std.mem.eql(u8, canonical_labels, labels_value.string)) return error.InvalidMarketCatalog;

    return .{
        .series_id = try parseMarketSeriesId(id_value),
        .schema_digest = market_identity.digestFromHex(digest_value.string) catch return error.InvalidMarketCatalog,
        .metric = try alloc.dupe(u8, metric_value.string),
        .canonical_labels = canonical_labels,
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

pub fn writeMarketSeriesIdentity(jw: *std.json.Stringify, entry: MarketSeriesIdentity) !void {
    var id_buffer: [20]u8 = undefined;
    const id_text = try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.series_id});
    const digest_text = market_identity.digestToHex(entry.schema_digest);

    try jw.beginObject();
    try jw.objectField("series_id");
    try jw.write(id_text);
    try jw.objectField("schema_digest");
    try jw.write(&digest_text);
    try jw.objectField("metric");
    try jw.write(entry.metric);
    try jw.objectField("canonical_labels");
    try jw.write(entry.canonical_labels);
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

fn findSchema(entries: []const MarketSchema, metric: []const u8) ?MarketSchema {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.metric, metric)) return entry;
    }
    return null;
}

fn findMarketSeriesById(
    entries: []const MarketSeriesIdentity,
    series_id: market_identity.MarketSeriesId,
) ?MarketSeriesIdentity {
    for (entries) |entry| {
        if (entry.series_id == series_id) return entry;
    }
    return null;
}

fn resolveMarketSeriesRegistration(
    entries: []const MarketSeriesIdentity,
    series_id: market_identity.MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
    schema_digest: market_identity.SchemaDigest,
) !?MarketSeriesIdentity {
    const existing = findMarketSeriesById(entries, series_id) orelse return null;
    if (!existing.sameIdentity(metric, canonical_labels)) return error.MarketSeriesConflict;
    if (!std.mem.eql(u8, &existing.schema_digest, &schema_digest)) {
        return error.MarketSchemaConflict;
    }
    return existing;
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
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| alloc.free(item);
        alloc.free(result);
    }
    for (value.array.items, 0..) |item, idx| {
        if (item != .string) return error.InvalidMarketCatalog;
        result[idx] = try alloc.dupe(u8, item.string);
        initialized += 1;
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
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| alloc.free(item);
        alloc.free(result);
    }
    for (items, 0..) |item, idx| {
        result[idx] = try alloc.dupe(u8, item);
        initialized += 1;
    }
    return result;
}

fn cloneConstStringArray(alloc: std.mem.Allocator, items: []const []const u8) ![][]u8 {
    const result = try alloc.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |item| alloc.free(item);
        alloc.free(result);
    }
    for (items, 0..) |item, idx| {
        result[idx] = try alloc.dupe(u8, item);
        initialized += 1;
    }
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
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |*entry| entry.deinit(alloc);
        alloc.free(out);
    }
    for (entries, 0..) |entry, idx| {
        out[idx] = try entry.clone(alloc);
        initialized += 1;
    }
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

fn parseMarketSeriesId(value: std.json.Value) !market_identity.MarketSeriesId {
    return switch (value) {
        .integer => |int| if (int < 0)
            error.InvalidMarketCatalog
        else
            @intCast(int),
        .number_string => |digits| std.fmt.parseInt(
            market_identity.MarketSeriesId,
            digits,
            10,
        ) catch error.InvalidMarketCatalog,
        .string => |digits| std.fmt.parseInt(
            market_identity.MarketSeriesId,
            digits,
            10,
        ) catch error.InvalidMarketCatalog,
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

test "fresh catalog can seed native builtins without promoting an existing catalog" {
    const alloc = std.testing.allocator;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var catalog = try Catalog.loadOrInitWithOptions(alloc, tmp.dir, .none, .{
            .new_catalog_builtin_mapping = .native_v1,
        });
        defer catalog.deinit();

        const builtin_metrics = [_][]const u8{ "market.trade", "market.quote", "market.bar" };
        for (builtin_metrics) |metric| {
            var schema = catalog.getSchema(metric) orelse return error.MissingMarketSchema;
            defer schema.deinit(alloc);
            try std.testing.expectEqual(StorageMapping.native_v1, schema.storage_mapping);
        }
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{
            .sub_path = path,
            .data =
            \\{"schemas":[{"metric":"market.existing","ordered_columns":["price"],"required_labels":["symbol"],"storage_mapping":"native_v1"}],"market_series":[],"bar_policies":[],"rollups":[],"signals":[]}
            ,
            .flags = .{},
        });

        var catalog = try Catalog.loadOrInitWithOptions(alloc, tmp.dir, .none, .{
            .new_catalog_builtin_mapping = .native_v1,
        });
        defer catalog.deinit();

        var existing = catalog.getSchema("market.existing") orelse return error.MissingMarketSchema;
        defer existing.deinit(alloc);
        try std.testing.expectEqual(StorageMapping.native_v1, existing.storage_mapping);

        const builtin_metrics = [_][]const u8{ "market.trade", "market.quote", "market.bar" };
        for (builtin_metrics) |metric| {
            var schema = catalog.getSchema(metric) orelse return error.MissingMarketSchema;
            defer schema.deinit(alloc);
            try std.testing.expectEqual(StorageMapping.fanout_v1, schema.storage_mapping);
        }
    }
}

test "catalog promotion rewrites schema mappings and registered digests atomically" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();
    var identity = try catalog.registerMarketSeries(
        "market.trade",
        "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
    );
    defer identity.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), try catalog.promoteAllSchemasToNative());
    try std.testing.expectEqual(@as(usize, 0), try catalog.promoteAllSchemasToNative());

    var promoted_schema = catalog.getSchema("market.trade").?;
    defer promoted_schema.deinit(alloc);
    try std.testing.expectEqual(StorageMapping.native_v1, promoted_schema.storage_mapping);
    var promoted_identity = catalog.getMarketSeries(identity.series_id).?;
    defer promoted_identity.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        promoted_schema.digest()[0..],
        promoted_identity.schema_digest[0..],
    );

    var reloaded = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer reloaded.deinit();
    var reloaded_schema = reloaded.getSchema("market.trade").?;
    defer reloaded_schema.deinit(alloc);
    try std.testing.expectEqual(StorageMapping.native_v1, reloaded_schema.storage_mapping);
    var reloaded_identity = reloaded.getMarketSeries(identity.series_id).?;
    defer reloaded_identity.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        reloaded_schema.digest()[0..],
        reloaded_identity.schema_digest[0..],
    );
}

test "storage mapping parses native mapping and rejects unknown mappings" {
    try std.testing.expectEqual(StorageMapping.fanout_v1, StorageMapping.parse("FANOUT_V1").?);
    try std.testing.expectEqual(StorageMapping.native_v1, StorageMapping.parse("native_v1").?);
    try std.testing.expect(StorageMapping.parse("dual_write_v1") == null);
}

test "catalog registration enforces schema and identity shape" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();

    try std.testing.expectError(
        error.InvalidMarketMetric,
        catalog.registerSchema(.{
            .metric = "",
            .ordered_columns = &.{"price"},
            .required_labels = &.{"symbol"},
        }),
    );
    try std.testing.expectError(
        error.DuplicateMarketColumn,
        catalog.registerSchema(.{
            .metric = "market.invalid",
            .ordered_columns = &.{ "price", "price" },
            .required_labels = &.{"symbol"},
        }),
    );
    try std.testing.expectError(
        error.MissingRequiredMarketLabel,
        catalog.registerMarketSeries("market.trade", "{\"symbol\":\"AAPL\"}"),
    );
    try std.testing.expectError(
        error.InvalidTagsJson,
        catalog.registerMarketSeries("market.trade", "[]"),
    );

    const canonical_labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const expected_id = market_identity.seriesId("market.trade", canonical_labels);
    try std.testing.expectError(
        error.MarketSeriesIdMismatch,
        catalog.registerMarketSeriesWithId(
            expected_id +% 1,
            "market.trade",
            canonical_labels,
        ),
    );
    var registered = try catalog.registerMarketSeriesWithId(
        expected_id,
        "market.trade",
        canonical_labels,
    );
    defer registered.deinit(alloc);
    try std.testing.expectEqual(expected_id, registered.series_id);
}

test "market catalog batch registration is atomic on later identity validation failure" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();

    const first_labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const second_labels = "{\"symbol\":\"MSFT\",\"venue\":\"XNAS\"}";
    const colliding_id = market_identity.seriesId("market.trade", first_labels);
    try std.testing.expectError(
        error.MarketSeriesIdMismatch,
        catalog.registerCanonicalMarketSeriesBatch(&.{
            .{
                .series_id = market_identity.seriesId("market.trade", "{\"symbol\":\"TSLA\",\"venue\":\"XNAS\"}"),
                .metric = "market.trade",
                .canonical_labels = "{\"symbol\":\"TSLA\",\"venue\":\"XNAS\"}",
            },
            .{
                .series_id = colliding_id,
                .metric = "market.trade",
                .canonical_labels = second_labels,
            },
        }),
    );

    const entries = try catalog.listMarketSeries();
    defer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "market catalog metric index returns owned identities without unrelated series" {
    const alloc = std.testing.allocator;
    var catalog = Catalog.initEmpty(alloc, .none);
    defer catalog.deinit();

    var wanted_schema = try catalog.registerSchema(.{
        .metric = "market.wanted",
        .ordered_columns = &.{"value"},
        .required_labels = &.{"symbol"},
    });
    defer wanted_schema.deinit(alloc);
    var unrelated_schema = try catalog.registerSchema(.{
        .metric = "market.unrelated",
        .ordered_columns = &.{"value"},
        .required_labels = &.{"symbol"},
    });
    defer unrelated_schema.deinit(alloc);

    for (0..64) |idx| {
        const labels = try std.fmt.allocPrint(alloc, "{{\"symbol\":\"U{d}\"}}", .{idx});
        defer alloc.free(labels);
        var identity = try catalog.registerMarketSeries("market.unrelated", labels);
        identity.deinit(alloc);
    }
    for (0..2) |idx| {
        const labels = try std.fmt.allocPrint(alloc, "{{\"symbol\":\"W{d}\"}}", .{idx});
        defer alloc.free(labels);
        var identity = try catalog.registerMarketSeries("market.wanted", labels);
        identity.deinit(alloc);
    }

    try std.testing.expectEqual(
        @as(usize, 2),
        catalog.market_series_by_metric.get("market.wanted").?.items.len,
    );
    try std.testing.expectEqual(
        @as(usize, 64),
        catalog.market_series_by_metric.get("market.unrelated").?.items.len,
    );
    const wanted = try catalog.listMarketSeriesForMetric("market.wanted");
    defer {
        for (wanted) |*entry| entry.deinit(alloc);
        alloc.free(wanted);
    }
    try std.testing.expectEqual(@as(usize, 2), wanted.len);
    for (wanted) |entry| {
        try std.testing.expectEqualStrings("market.wanted", entry.metric);
    }
    wanted[0].canonical_labels[0] = '[';
    var stored = catalog.getMarketSeries(wanted[0].series_id).?;
    defer stored.deinit(alloc);
    try std.testing.expect(!std.mem.eql(
        u8,
        wanted[0].canonical_labels,
        stored.canonical_labels,
    ));
}

test "market catalog rejects malformed and duplicate persisted schemas" {
    const alloc = std.testing.allocator;
    const invalid_catalogs = [_][]const u8{
        \\{"schemas":[{"metric":"market.bad","ordered_columns":["price"],"required_labels":[]},{"metric":"market.bad","ordered_columns":["price"],"required_labels":[]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        \\{"schemas":[{"metric":"","ordered_columns":["price"],"required_labels":[]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        \\{"schemas":[{"metric":"market.bad","ordered_columns":[],"required_labels":[]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        \\{"schemas":[{"metric":"market.bad","ordered_columns":["price","price"],"required_labels":[]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        \\{"schemas":[{"metric":"market.bad","ordered_columns":["price"],"required_labels":["symbol","symbol"]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        \\{"schemas":[{"metric":"market.bad","metric":"market.other","ordered_columns":["price"],"required_labels":[]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
    };

    for (invalid_catalogs) |body| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = path, .data = body, .flags = .{} });
        try std.testing.expectError(
            error.InvalidMarketCatalog,
            Catalog.loadOrInit(alloc, tmp.dir, .none),
        );
    }
}

test "market catalog rejects invalid persisted series ids and labels" {
    const alloc = std.testing.allocator;
    const zero_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const invalid_ids = [_][]const u8{
        "-1",
        "\"18446744073709551616\"",
        "\"not-an-id\"",
    };
    for (invalid_ids) |invalid_id| {
        const body = try std.fmt.allocPrint(
            alloc,
            "{{\"schemas\":[{{\"metric\":\"market.trade\",\"ordered_columns\":[\"price\",\"size\"],\"required_labels\":[\"symbol\",\"venue\"]}}],\"market_series\":[{{\"series_id\":{s},\"schema_digest\":\"{s}\",\"metric\":\"market.trade\",\"canonical_labels\":\"{{\\\"symbol\\\":\\\"AAPL\\\",\\\"venue\\\":\\\"XNAS\\\"}}\"}}],\"bar_policies\":[],\"rollups\":[],\"signals\":[]}}",
            .{ invalid_id, zero_digest },
        );
        defer alloc.free(body);

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = path, .data = body, .flags = .{} });
        try std.testing.expectError(
            error.InvalidMarketCatalog,
            Catalog.loadOrInit(alloc, tmp.dir, .none),
        );
    }

    const incomplete_labels = "{\"symbol\":\"AAPL\"}";
    const series_id = market_identity.seriesId("market.trade", incomplete_labels);
    const digest = market_identity.schemaDigest(
        "market.trade",
        &.{ "price", "size" },
        &.{ "symbol", "venue" },
        "fanout_v1",
    );
    const digest_hex = market_identity.digestToHex(digest);
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"schemas\":[{{\"metric\":\"market.trade\",\"ordered_columns\":[\"price\",\"size\"],\"required_labels\":[\"symbol\",\"venue\"]}}],\"market_series\":[{{\"series_id\":\"{d}\",\"schema_digest\":\"{s}\",\"metric\":\"market.trade\",\"canonical_labels\":\"{{\\\"symbol\\\":\\\"AAPL\\\"}}\"}}],\"bar_policies\":[],\"rollups\":[],\"signals\":[]}}",
        .{ series_id, &digest_hex },
    );
    defer alloc.free(body);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = path, .data = body, .flags = .{} });
    try std.testing.expectError(
        error.InvalidMarketCatalog,
        Catalog.loadOrInit(alloc, tmp.dir, .none),
    );
}

test "market catalog loads historical schemas without a storage mapping as fanout" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = path,
        .data =
        \\{"schemas":[{"metric":"legacy.market","ordered_columns":["price","size"],"required_labels":["symbol"]}],"bar_policies":[],"rollups":[],"signals":[]}
        ,
        .flags = .{},
    });

    var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
    defer catalog.deinit();
    var schema = catalog.getSchema("legacy.market") orelse return error.MissingLegacySchema;
    defer schema.deinit(alloc);
    try std.testing.expectEqual(StorageMapping.fanout_v1, schema.storage_mapping);

    const rewritten = try tmp.dir.readFileAlloc(alloc, path, 1024 * 1024);
    defer alloc.free(rewritten);
    try std.testing.expect(std.mem.indexOf(
        u8,
        rewritten,
        "\"metric\":\"legacy.market\",\"ordered_columns\":[\"price\",\"size\"],\"required_labels\":[\"symbol\"],\"storage_mapping\":\"fanout_v1\"",
    ) != null);
}

test "native schema mapping and market identity persist across restart" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var expected_id: market_identity.MarketSeriesId = undefined;
    var expected_digest: market_identity.SchemaDigest = undefined;
    {
        var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
        defer catalog.deinit();

        var schema = try catalog.registerSchema(.{
            .metric = "market.synthetic",
            .ordered_columns = &.{ "price", "size", "imbalance" },
            .required_labels = &.{ "symbol", "venue" },
            .storage_mapping = .native_v1,
        });
        defer schema.deinit(alloc);
        expected_digest = schema.digest();

        var registered = try catalog.registerMarketSeries(
            "market.synthetic",
            "{\"venue\":\"XNAS\",\"symbol\":\"AAPL\"}",
        );
        defer registered.deinit(alloc);
        expected_id = registered.series_id;
        try std.testing.expectEqualStrings(
            "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            registered.canonical_labels,
        );
        try std.testing.expectEqualSlices(u8, &expected_digest, &registered.schema_digest);
    }

    {
        var catalog = try Catalog.loadOrInit(alloc, tmp.dir, .none);
        defer catalog.deinit();

        var schema = catalog.getSchema("market.synthetic") orelse return error.MissingNativeSchema;
        defer schema.deinit(alloc);
        try std.testing.expectEqual(StorageMapping.native_v1, schema.storage_mapping);

        var registered = catalog.getMarketSeries(expected_id) orelse return error.MissingMarketSeries;
        defer registered.deinit(alloc);
        try std.testing.expectEqualStrings("market.synthetic", registered.metric);
        try std.testing.expectEqualStrings(
            "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}",
            registered.canonical_labels,
        );
        try std.testing.expectEqualSlices(u8, &expected_digest, &registered.schema_digest);
    }
}

test "market series registration rejects a stored id collision" {
    const digest = market_identity.schemaDigest(
        "market.first",
        &.{"price"},
        &.{"symbol"},
        "native_v1",
    );
    const entries = [_]MarketSeriesIdentity{.{
        .series_id = 7,
        .schema_digest = digest,
        .metric = @constCast("market.first"),
        .canonical_labels = @constCast("{\"symbol\":\"AAPL\"}"),
    }};

    try std.testing.expectError(
        error.MarketSeriesConflict,
        resolveMarketSeriesRegistration(
            &entries,
            7,
            "market.second",
            "{\"symbol\":\"AAPL\"}",
            digest,
        ),
    );
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
