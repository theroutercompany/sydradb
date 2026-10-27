const std = @import("std");
const cfg = @import("../config.zig");
const engine_mod = @import("../engine.zig");
const types = @import("../types.zig");
const cas_mod = @import("cas.zig");
const market_catalog_mod = @import("market_catalog.zig");
const market_identity = @import("market_identity.zig");
const market_manifest_mod = @import("market_manifest.zig");
const market_migration = @import("market_migration.zig");
const market_segment = @import("market_segment.zig");

const hour_ns: i64 = 3600 * std.time.ns_per_s;

const PromotionFault = enum {
    after_format_promotion,
    after_catalog_promotion,
};

var promotion_fault: ?PromotionFault = null;

pub const Command = union(enum) {
    status,
    migrate_dry_run,
    migrate_apply: struct {
        resume_failed: bool,
    },
    verify,
    promote_apply,
};

pub fn parseCommand(args: []const []const u8) !Command {
    if (args.len == 1 and std.mem.eql(u8, args[0], "status")) return .status;
    if (args.len == 1 and std.mem.eql(u8, args[0], "verify")) return .verify;
    if (args.len == 2 and
        std.mem.eql(u8, args[0], "promote") and
        std.mem.eql(u8, args[1], "--apply"))
    {
        return .promote_apply;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[0], "migrate")) {
        if (args.len == 2 and std.mem.eql(u8, args[1], "--dry-run")) {
            return .migrate_dry_run;
        }
        if (std.mem.eql(u8, args[1], "--apply")) {
            if (args.len == 2) return .{ .migrate_apply = .{ .resume_failed = false } };
            if (args.len == 3 and std.mem.eql(u8, args[2], "--resume")) {
                return .{ .migrate_apply = .{ .resume_failed = true } };
            }
        }
    }
    return error.InvalidMarketStorageCommand;
}

pub fn executeAlloc(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    command: Command,
) ![]u8 {
    return switch (command) {
        .status => try statusAlloc(alloc, engine),
        .migrate_dry_run => try dryRunAlloc(alloc, engine),
        .migrate_apply => |options| try migrateApplyAlloc(alloc, engine, options.resume_failed),
        .verify => try verifyAlloc(alloc, engine),
        .promote_apply => try promoteApplyAlloc(alloc, engine),
    };
}

const Status = struct {
    repository_format: u16,
    phase: market_migration.Phase,
    generation: u64,
    checkpoint_ref: ?[]const u8,
    fanout_schemas: u64,
    native_schemas: u64,
    registered_series: u64,
    native_segments: u64,
    native_rows: u64,
    completed_series: u64,
    pending_series: u64,
    failure_code: ?[]const u8,
    failure_message: ?[]const u8,
};

fn statusAlloc(alloc: std.mem.Allocator, engine: *engine_mod.Engine) ![]u8 {
    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    defer state.deinit();

    const schemas = try engine.listMarketSchemas();
    defer deinitSchemas(alloc, schemas);
    const series = try engine.metadata.market_catalog.listMarketSeries();
    defer deinitSeries(alloc, series);

    var fanout_schemas: u64 = 0;
    var native_schemas: u64 = 0;
    for (schemas) |schema| switch (schema.storage_mapping) {
        .fanout_v1 => fanout_schemas += 1,
        .native_v1 => native_schemas += 1,
    };

    var native_rows: u64 = 0;
    for (engine.market_manifest.list()) |descriptor| {
        native_rows = try std.math.add(u64, native_rows, descriptor.row_count);
    }
    var completed_series: u64 = 0;
    for (state.progress.items) |progress| {
        if (progress.completed) completed_series += 1;
    }
    const failure = state.failure;
    return try writeStatusJson(alloc, .{
        .repository_format = engine.repository_format.version,
        .phase = state.phase,
        .generation = state.generation,
        .checkpoint_ref = state.checkpoint_ref,
        .fanout_schemas = fanout_schemas,
        .native_schemas = native_schemas,
        .registered_series = @intCast(series.len),
        .native_segments = @intCast(engine.market_manifest.list().len),
        .native_rows = native_rows,
        .completed_series = completed_series,
        .pending_series = @intCast(state.progress.items.len - completed_series),
        .failure_code = if (failure) |entry| entry.code else null,
        .failure_message = if (failure) |entry| entry.message else null,
    });
}

const OwnedFanoutSeries = struct {
    input: market_migration.FanoutSeriesInput,
    columns: []market_migration.FanoutColumnInput,
    values: [][]market_migration.FanoutValue,
    schema_index: usize,

    fn deinit(self: *OwnedFanoutSeries, alloc: std.mem.Allocator) void {
        for (self.values) |entries| alloc.free(entries);
        alloc.free(self.values);
        alloc.free(self.columns);
        self.* = undefined;
    }
};

const Dataset = struct {
    alloc: std.mem.Allocator,
    schemas: []market_catalog_mod.MarketSchema,
    identities: []market_catalog_mod.MarketSeriesIdentity,
    series: []OwnedFanoutSeries,
    inputs: []market_migration.FanoutSeriesInput,

    fn deinit(self: *Dataset) void {
        for (self.series) |*entry| entry.deinit(self.alloc);
        self.alloc.free(self.series);
        self.alloc.free(self.inputs);
        deinitSchemas(self.alloc, self.schemas);
        deinitSeries(self.alloc, self.identities);
        self.* = undefined;
    }
};

fn buildDataset(alloc: std.mem.Allocator, engine: *engine_mod.Engine) !Dataset {
    const schemas = try engine.listMarketSchemas();
    var schemas_owned = true;
    errdefer if (schemas_owned) deinitSchemas(alloc, schemas);
    const identities = try engine.metadata.market_catalog.listMarketSeries();
    var identities_owned = true;
    errdefer if (identities_owned) deinitSeries(alloc, identities);

    var owned = std.array_list.Managed(OwnedFanoutSeries).init(alloc);
    var owned_transferred = false;
    defer if (!owned_transferred) {
        for (owned.items) |*entry| entry.deinit(alloc);
        owned.deinit();
    };

    for (identities) |identity| {
        const schema_index = findSchemaIndex(schemas, identity.metric) orelse
            return error.UnknownMarketSchema;
        const schema = schemas[schema_index];
        if (schema.storage_mapping != .fanout_v1) continue;
        const expected_digest = schema.digest();
        if (!std.mem.eql(u8, expected_digest[0..], identity.schema_digest[0..])) {
            return error.MarketSchemaMismatch;
        }

        const columns = try alloc.alloc(
            market_migration.FanoutColumnInput,
            schema.ordered_columns.len,
        );
        var columns_owned = true;
        errdefer if (columns_owned) alloc.free(columns);
        const values = try alloc.alloc(
            []market_migration.FanoutValue,
            schema.ordered_columns.len,
        );
        var values_len: usize = 0;
        errdefer {
            for (values[0..values_len]) |entries| alloc.free(entries);
            alloc.free(values);
        }

        var source_bytes: u64 = 0;
        for (schema.ordered_columns, 0..) |column_name, column_index| {
            const scalar_metric = try std.fmt.allocPrint(
                alloc,
                "{s}.{s}",
                .{ schema.metric, column_name },
            );
            defer alloc.free(scalar_metric);
            const scalar_series_id = types.seriesIdFrom(
                scalar_metric,
                identity.canonical_labels,
            );
            var points = std.array_list.Managed(types.Point).init(alloc);
            defer points.deinit();
            try engine.queryRange(
                scalar_series_id,
                std.math.minInt(i64),
                std.math.maxInt(i64),
                &points,
            );

            const column_values = try alloc.alloc(
                market_migration.FanoutValue,
                points.items.len,
            );
            for (points.items, 0..) |point, point_index| {
                column_values[point_index] = market_migration.FanoutValue.fromF64(
                    point.ts,
                    point.value,
                );
            }
            values[column_index] = column_values;
            values_len += 1;
            columns[column_index] = .{
                .name = column_name,
                .values = column_values,
            };
            source_bytes = try std.math.add(
                u64,
                source_bytes,
                try std.math.mul(u64, @intCast(column_values.len), @sizeOf(types.Point)),
            );
        }

        try owned.append(.{
            .input = .{
                .schema_digest = identity.schema_digest,
                .market_series_id = identity.series_id,
                .metric = identity.metric,
                .canonical_labels = identity.canonical_labels,
                .ordered_columns = schema.ordered_columns,
                .columns = columns,
                .source_bytes = source_bytes,
            },
            .columns = columns,
            .values = values,
            .schema_index = schema_index,
        });
        columns_owned = false;
    }

    std.mem.sort(OwnedFanoutSeries, owned.items, {}, ownedSeriesLessThan);
    const inputs = try alloc.alloc(market_migration.FanoutSeriesInput, owned.items.len);
    errdefer alloc.free(inputs);
    for (owned.items, 0..) |entry, index| inputs[index] = entry.input;
    const series = try owned.toOwnedSlice();
    owned_transferred = true;
    schemas_owned = false;
    identities_owned = false;
    return .{
        .alloc = alloc,
        .schemas = schemas,
        .identities = identities,
        .series = series,
        .inputs = inputs,
    };
}

fn dryRunAlloc(alloc: std.mem.Allocator, engine: *engine_mod.Engine) ![]u8 {
    try establishFanoutBoundary(engine);
    var dataset = try buildDataset(alloc, engine);
    defer dataset.deinit();
    var report = try market_migration.inventoryFanout(alloc, dataset.inputs);
    defer report.deinit();
    return try writeInventoryJson(alloc, "dry-run", report);
}

fn migrateApplyAlloc(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    resume_failed: bool,
) ![]u8 {
    return migrateApplyInner(alloc, engine, resume_failed) catch |err| {
        if (shouldPersistFailure(err)) {
            persistFailure(alloc, engine.data_dir, err);
        }
        return err;
    };
}

fn migrateApplyInner(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    resume_failed: bool,
) ![]u8 {
    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    defer state.deinit();
    if (state.phase == .failed) {
        if (!resume_failed) return error.MarketMigrationResumeRequired;
        try state.resumeFailure();
        try state.saveAtomically(engine.data_dir);
    } else if (state.phase == .reconstructing and !resume_failed) {
        return error.MarketMigrationResumeRequired;
    } else if (resume_failed and state.phase == .inventory) {
        return error.MarketMigrationNotFailed;
    }
    switch (state.phase) {
        .inventory, .reconstructing => {},
        .native_complete, .verifying, .verified, .checkpointed => {
            try establishFanoutBoundary(engine);
            try engine.refreshNextMarketWriteSequenceFromPersistedSegments();
            try syncMigrationSnapshot(
                alloc,
                engine,
                "market-migration-resume-publication",
            );
            return try writeMigrationResultJson(
                alloc,
                "migrate",
                state.phase,
                state.generation,
                0,
                0,
            );
        },
        .promoting, .promoted => return error.InvalidMarketMigrationPhase,
        .failed => unreachable,
    }

    try establishFanoutBoundary(engine);
    var dataset = try buildDataset(alloc, engine);
    defer dataset.deinit();
    var inventory = try market_migration.inventoryFanout(alloc, dataset.inputs);
    defer inventory.deinit();
    if (inventory.blocker_count != 0) return error.MarketMigrationBlocked;

    if (state.phase == .inventory) {
        _ = try state.advance(.reconstructing);
        try state.saveAtomically(engine.data_dir);
    }

    var rows_written: u64 = 0;
    var segments_written: u64 = 0;
    for (dataset.series) |entry| {
        const key = market_migration.ProgressKey{
            .schema_digest = entry.input.schema_digest,
            .market_series_id = entry.input.market_series_id,
        };
        if (findProgress(state.progress.items, key)) |progress| {
            if (progress.completed) continue;
        }

        var reconstruction = try market_migration.reconstructFanoutSeries(
            alloc,
            entry.input,
        );
        defer reconstruction.deinit();
        if (reconstruction.blockerCount() != 0) return error.MarketMigrationBlocked;

        const schema = dataset.schemas[entry.schema_index];
        const target_digest = market_identity.schemaDigest(
            schema.metric,
            schema.ordered_columns,
            schema.required_labels,
            market_catalog_mod.StorageMapping.native_v1.text(),
        );
        const written = try materializeSeries(
            alloc,
            engine,
            entry.input,
            target_digest,
            reconstruction.rows,
        );
        rows_written = try std.math.add(u64, rows_written, written.rows);
        segments_written = try std.math.add(u64, segments_written, written.segments);

        _ = try state.recordProgress(
            key,
            if (reconstruction.rows.len == 0)
                null
            else
                reconstruction.rows[reconstruction.rows.len - 1].ts_ns,
            @intCast(reconstruction.rows.len),
            true,
        );
        try state.saveAtomically(engine.data_dir);
    }

    _ = try state.advance(.native_complete);
    try state.saveAtomically(engine.data_dir);
    try engine.refreshNextMarketWriteSequenceFromPersistedSegments();
    try syncMigrationSnapshot(alloc, engine, "market-migration-native-complete");
    return try writeMigrationResultJson(
        alloc,
        "migrate",
        state.phase,
        state.generation,
        rows_written,
        segments_written,
    );
}

const MaterializeResult = struct {
    rows: u64,
    segments: u64,
};

fn materializeSeries(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    input: market_migration.FanoutSeriesInput,
    target_digest: market_identity.SchemaDigest,
    rows: []const market_migration.ReconstructedRow,
) !MaterializeResult {
    if (rows.len == 0) return .{ .rows = 0, .segments = 0 };

    var additions = std.array_list.Managed(market_manifest_mod.AddInput).init(alloc);
    defer {
        for (additions.items) |addition| alloc.free(@constCast(addition.path));
        additions.deinit();
    }

    var start: usize = 0;
    while (start < rows.len) {
        const hour = @divFloor(rows[start].ts_ns, hour_ns);
        var end = start + 1;
        while (end < rows.len and @divFloor(rows[end].ts_ns, hour_ns) == hour) : (end += 1) {}

        const views = try alloc.alloc(market_segment.MarketRowView, end - start);
        defer alloc.free(views);
        const values = try alloc.alloc([]f64, end - start);
        var values_len: usize = 0;
        defer {
            for (values[0..values_len]) |entry| alloc.free(entry);
            alloc.free(values);
        }
        for (rows[start..end], 0..) |row, row_index| {
            const row_values = try alloc.alloc(f64, row.value_bits.len);
            values[row_index] = row_values;
            values_len += 1;
            for (row.value_bits, 0..) |bits, column_index| {
                row_values[column_index] = @bitCast(bits);
            }
            views[row_index] = .{
                .ts_ns = row.ts_ns,
                .write_sequence = @intCast(start + row_index + 1),
                .values = row_values,
            };
        }

        const path = try market_segment.write(
            alloc,
            engine.data_dir,
            .{
                .market_series_id = input.market_series_id,
                .schema_digest = target_digest,
                .metric = input.metric,
                .canonical_labels = input.canonical_labels,
                .hour = hour,
                .column_names = input.ordered_columns,
            },
            views,
        );
        errdefer alloc.free(path);
        const bytes = try engine.data_dir.readFileAlloc(alloc, path, 128 * 1024 * 1024);
        defer alloc.free(bytes);
        const digest = market_manifest_mod.contentDigest(bytes);
        try additions.append(.{
            .path = path,
            .market_series_id = input.market_series_id,
            .schema_digest = target_digest,
            .metric = input.metric,
            .canonical_labels = input.canonical_labels,
            .hour_bucket = hour,
            .start_ts_ns = rows[start].ts_ns,
            .end_ts_ns = rows[end - 1].ts_ns,
            .row_count = @intCast(end - start),
            .block_count = @intCast(
                std.math.divCeil(
                    usize,
                    end - start,
                    market_segment.market_segment_block_rows,
                ) catch unreachable,
            ),
            .column_names = input.ordered_columns,
            .content_id = digest,
            .file_hash = digest,
            .file_size = @intCast(bytes.len),
        });
        start = end;
    }

    try engine.market_manifest.addBatch(engine.data_dir, additions.items);
    return .{
        .rows = @intCast(rows.len),
        .segments = @intCast(additions.items.len),
    };
}

fn verifyAlloc(alloc: std.mem.Allocator, engine: *engine_mod.Engine) ![]u8 {
    return verifyInner(alloc, engine) catch |err| {
        if (shouldPersistFailure(err)) {
            persistFailure(alloc, engine.data_dir, err);
        }
        return err;
    };
}

fn verifyInner(alloc: std.mem.Allocator, engine: *engine_mod.Engine) ![]u8 {
    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    defer state.deinit();
    if (state.phase == .failed) return error.MarketMigrationResumeRequired;
    switch (state.phase) {
        .native_complete => {
            _ = try state.advance(.verifying);
            try state.saveAtomically(engine.data_dir);
        },
        .verifying, .verified, .checkpointed => {},
        else => return error.InvalidMarketMigrationPhase,
    }

    try establishFanoutBoundary(engine);
    const rows_verified = try verifyDatasetParity(alloc, engine);
    try syncMigrationSnapshot(alloc, engine, "market-migration-verified");
    if (state.phase == .verifying) {
        _ = try state.advance(.verified);
        try state.saveAtomically(engine.data_dir);
    }
    return try writeVerifyJson(alloc, state.phase, state.generation, rows_verified);
}

fn verifyDatasetParity(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
) !u64 {
    var dataset = try buildDataset(alloc, engine);
    defer dataset.deinit();
    var rows_verified: u64 = 0;
    for (dataset.series) |entry| {
        var reconstruction = try market_migration.reconstructFanoutSeries(
            alloc,
            entry.input,
        );
        defer reconstruction.deinit();
        if (reconstruction.blockerCount() != 0) return error.MarketMigrationBlocked;
        const schema = dataset.schemas[entry.schema_index];
        const target_digest = market_identity.schemaDigest(
            schema.metric,
            schema.ordered_columns,
            schema.required_labels,
            market_catalog_mod.StorageMapping.native_v1.text(),
        );
        try verifySeries(
            alloc,
            engine,
            entry.input,
            target_digest,
            reconstruction.rows,
        );
        rows_verified = try std.math.add(
            u64,
            rows_verified,
            @intCast(reconstruction.rows.len),
        );
    }
    return rows_verified;
}

const ActualRow = struct {
    write_sequence: u64,
    value_bits: []u64,

    fn deinit(self: *ActualRow, alloc: std.mem.Allocator) void {
        alloc.free(self.value_bits);
        self.* = undefined;
    }
};

fn verifySeries(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    input: market_migration.FanoutSeriesInput,
    target_digest: market_identity.SchemaDigest,
    expected: []const market_migration.ReconstructedRow,
) !void {
    var actual = std.AutoHashMap(i64, ActualRow).init(alloc);
    defer {
        var values = actual.valueIterator();
        while (values.next()) |entry| entry.deinit(alloc);
        actual.deinit();
    }
    var matching_segments: usize = 0;
    for (engine.market_manifest.list()) |descriptor| {
        if (descriptor.market_series_id != input.market_series_id or
            !std.mem.eql(u8, descriptor.schema_digest[0..], target_digest[0..]))
        {
            continue;
        }
        matching_segments += 1;
        var decoded = try market_segment.readAll(alloc, engine.data_dir, descriptor.path);
        defer decoded.deinit(alloc);
        if (decoded.metadata.market_series_id != input.market_series_id or
            !std.mem.eql(
                u8,
                decoded.metadata.schema_digest[0..],
                target_digest[0..],
            ) or
            !std.mem.eql(u8, decoded.metadata.metric, input.metric) or
            !std.mem.eql(
                u8,
                decoded.metadata.canonical_labels,
                input.canonical_labels,
            ) or
            decoded.metadata.column_names.len != input.ordered_columns.len or
            decoded.columns.len != input.ordered_columns.len)
        {
            return error.MarketMigrationParityMismatch;
        }
        for (decoded.metadata.column_names, input.ordered_columns) |actual_name, expected_name| {
            if (!std.mem.eql(u8, actual_name, expected_name)) {
                return error.MarketMigrationParityMismatch;
            }
        }
        for (decoded.timestamps, 0..) |ts_ns, row_index| {
            const bits = try alloc.alloc(u64, decoded.columns.len);
            var bits_owned = true;
            defer if (bits_owned) alloc.free(bits);
            for (decoded.columns, 0..) |column, column_index| {
                bits[column_index] = @bitCast(column.values[row_index]);
            }
            const sequence = decoded.write_sequences[row_index];
            const gop = try actual.getOrPut(ts_ns);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .write_sequence = sequence,
                    .value_bits = bits,
                };
                bits_owned = false;
            } else if (sequence > gop.value_ptr.write_sequence) {
                gop.value_ptr.deinit(alloc);
                gop.value_ptr.* = .{
                    .write_sequence = sequence,
                    .value_bits = bits,
                };
                bits_owned = false;
            } else if (sequence == gop.value_ptr.write_sequence and
                !bitsEqual(bits, gop.value_ptr.value_bits))
            {
                return error.MarketMigrationParityMismatch;
            }
        }
    }
    if (expected.len != 0 and matching_segments == 0) {
        return error.NativeMarketDataUnavailable;
    }
    if (actual.count() != expected.len) return error.MarketMigrationParityMismatch;
    for (expected) |row| {
        const found = actual.get(row.ts_ns) orelse
            return error.MarketMigrationParityMismatch;
        if (!bitsEqual(row.value_bits, found.value_bits)) {
            return error.MarketMigrationParityMismatch;
        }
    }
}

fn promoteApplyAlloc(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
) ![]u8 {
    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    defer state.deinit();
    if (state.phase == .failed) return error.MarketMigrationResumeRequired;
    if (state.phase == .promoted) {
        return try writePromotionJson(
            alloc,
            state.phase,
            state.generation,
            state.checkpoint_ref.?,
            0,
            0,
        );
    }
    if (state.phase != .verified and
        state.phase != .checkpointed and
        state.phase != .promoting)
    {
        return error.MarketMigrationVerificationRequired;
    }

    var rows_verified: u64 = 0;
    if (state.phase == .verified or state.phase == .checkpointed) {
        try establishFanoutBoundary(engine);
        rows_verified = try verifyDatasetParity(alloc, engine);
    }
    if (state.phase == .verified) {
        const checkpoint_ref = try promotionCheckpointRefAlloc(alloc, state.generation);
        defer alloc.free(checkpoint_ref);
        if (!try checkpointRefExists(alloc, engine, checkpoint_ref)) {
            try syncMigrationSnapshot(alloc, engine, "market-migration-pre-promotion");
        }
        _ = try createPromotionCheckpoint(alloc, engine, checkpoint_ref);
        _ = try state.recordCheckpointRef(checkpoint_ref);
        _ = try state.advance(.checkpointed);
        try state.saveAtomically(engine.data_dir);
    } else if (state.phase == .checkpointed) {
        _ = try createPromotionCheckpoint(alloc, engine, state.checkpoint_ref.?);
    }

    if (state.phase == .checkpointed) {
        _ = try state.advance(.promoting);
        try state.saveAtomically(engine.data_dir);
    }

    try promoteRepositoryFormat(alloc, engine);
    try hitPromotionFault(.after_format_promotion);
    const promoted_schemas = try engine.metadata.market_catalog.promoteAllSchemasToNative();
    try hitPromotionFault(.after_catalog_promotion);

    try syncMigrationSnapshot(alloc, engine, "market-storage-promoted");
    try verifyMigrationSnapshot(alloc, engine);
    _ = try state.advance(.promoted);
    try state.saveAtomically(engine.data_dir);
    return try writePromotionJson(
        alloc,
        state.phase,
        state.generation,
        state.checkpoint_ref.?,
        promoted_schemas,
        rows_verified,
    );
}

fn promoteRepositoryFormat(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
) !void {
    if (engine.cas) |*cas| {
        _ = try cas.promoteFormatForNativeMarket();
        engine.repository_format = cas.format;
        return;
    }

    var cas = try cas_mod.CasManager.init(
        alloc,
        engine.config.data_dir,
        engine.config.fsync,
    );
    defer cas.deinit();
    _ = try cas.promoteFormatForNativeMarket();
    engine.repository_format = cas.format;
}

fn promotionCheckpointRefAlloc(
    alloc: std.mem.Allocator,
    verified_generation: u64,
) ![]u8 {
    return try std.fmt.allocPrint(
        alloc,
        "checkpoints/market-storage-promotion-g{d}",
        .{verified_generation},
    );
}

fn checkpointRefExists(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    ref_name: []const u8,
) !bool {
    if (engine.cas) |*cas| return (try cas.refs.readRef(ref_name)) != null;

    var cas = try cas_mod.CasManager.init(
        alloc,
        engine.config.data_dir,
        engine.config.fsync,
    );
    defer cas.deinit();
    return (try cas.refs.readRef(ref_name)) != null;
}

fn createPromotionCheckpoint(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    ref_name: []const u8,
) !bool {
    if (engine.cas) |*cas| return try cas.createCheckpointAtRef(ref_name);

    var cas = try cas_mod.CasManager.init(
        alloc,
        engine.config.data_dir,
        engine.config.fsync,
    );
    defer cas.deinit();
    return try cas.createCheckpointAtRef(ref_name);
}

fn hitPromotionFault(point: PromotionFault) !void {
    if (promotion_fault != point) return;
    promotion_fault = null;
    return switch (point) {
        .after_format_promotion => error.InjectedAfterMarketFormatPromotion,
        .after_catalog_promotion => error.InjectedAfterMarketCatalogPromotion,
    };
}

/// Capture a durable read boundary before inventorying fanout scalar series.
/// This drains acknowledged queue work and flushes the matching segment, CAS,
/// and WAL state while the repository still retains its format-3 mapping.
fn establishFanoutBoundary(engine: *engine_mod.Engine) !void {
    _ = try engine.flushNow();
}

fn syncMigrationSnapshot(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
    reason: []const u8,
) !void {
    if (engine.cas) |*cas| {
        return try syncMigrationSnapshotWithManager(engine, cas, reason);
    }
    var cas = try cas_mod.CasManager.init(
        alloc,
        engine.config.data_dir,
        engine.config.fsync,
    );
    defer cas.deinit();
    return try syncMigrationSnapshotWithManager(engine, &cas, reason);
}

fn syncMigrationSnapshotWithManager(
    engine: *engine_mod.Engine,
    cas: *cas_mod.CasManager,
    reason: []const u8,
) !void {
    if (try cas.refs.readHead(cas_mod.main_ref) == null) {
        _ = try cas.bootstrapIfMissingWithNativeMarket(
            engine.data_dir,
            &engine.metadata.manifest,
            &engine.metadata.tags,
            &engine.metadata.series_catalog,
            &engine.metadata.metric_catalog,
            &engine.metadata.market_catalog,
            &engine.market_manifest,
        );
    } else {
        _ = try cas.syncLegacySnapshotWithNativeMarket(
            engine.data_dir,
            &engine.metadata.manifest,
            &engine.metadata.tags,
            &engine.metadata.series_catalog,
            &engine.metadata.metric_catalog,
            &engine.metadata.market_catalog,
            &engine.market_manifest,
            reason,
        );
    }
}

fn verifyMigrationSnapshot(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
) !void {
    if (engine.cas) |*cas| {
        return try cas.verifyHeadMatchesLegacyWithNativeMarket(
            engine.data_dir,
            &engine.metadata.manifest,
            &engine.metadata.tags,
            &engine.metadata.series_catalog,
            &engine.metadata.metric_catalog,
            &engine.metadata.market_catalog,
            &engine.market_manifest,
        );
    }
    var cas = try cas_mod.CasManager.init(
        alloc,
        engine.config.data_dir,
        engine.config.fsync,
    );
    defer cas.deinit();
    return try cas.verifyHeadMatchesLegacyWithNativeMarket(
        engine.data_dir,
        &engine.metadata.manifest,
        &engine.metadata.tags,
        &engine.metadata.series_catalog,
        &engine.metadata.metric_catalog,
        &engine.metadata.market_catalog,
        &engine.market_manifest,
    );
}

fn persistFailure(
    alloc: std.mem.Allocator,
    data_dir: std.fs.Dir,
    err: anyerror,
) void {
    var state = market_migration.MigrationState.loadOrInit(alloc, data_dir) catch return;
    defer state.deinit();
    const code = @errorName(err);
    _ = state.markFailure(code, code) catch return;
    state.saveAtomically(data_dir) catch {};
}

fn shouldPersistFailure(err: anyerror) bool {
    return switch (err) {
        error.MarketMigrationResumeRequired,
        error.MarketMigrationNotFailed,
        error.MarketMigrationVerificationRequired,
        error.InvalidMarketMigrationPhase,
        error.InvalidMarketMigrationTransition,
        => false,
        else => true,
    };
}

fn writeStatusJson(alloc: std.mem.Allocator, status: Status) ![]u8 {
    var output = std.io.Writer.Allocating.init(alloc);
    errdefer output.deinit();
    var jw = std.json.Stringify{ .writer = &output.writer };
    try beginEnvelope(&jw, "status");
    try jw.objectField("repository_format");
    try jw.write(status.repository_format);
    try jw.objectField("phase");
    try jw.write(status.phase.text());
    try jw.objectField("generation");
    try jw.write(status.generation);
    try jw.objectField("checkpoint_ref");
    if (status.checkpoint_ref) |value| try jw.write(value) else try jw.write(null);
    try jw.objectField("schemas");
    try jw.beginObject();
    try jw.objectField("fanout_v1");
    try jw.write(status.fanout_schemas);
    try jw.objectField("native_v1");
    try jw.write(status.native_schemas);
    try jw.endObject();
    try jw.objectField("registered_series");
    try jw.write(status.registered_series);
    try jw.objectField("native_segments");
    try jw.write(status.native_segments);
    try jw.objectField("native_rows");
    try jw.write(status.native_rows);
    try jw.objectField("completed_series");
    try jw.write(status.completed_series);
    try jw.objectField("pending_series");
    try jw.write(status.pending_series);
    try jw.objectField("failure");
    if (status.failure_code) |code| {
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(code);
        try jw.objectField("message");
        try jw.write(status.failure_message.?);
        try jw.endObject();
    } else {
        try jw.write(null);
    }
    try jw.endObject();
    return try output.toOwnedSlice();
}

fn writeInventoryJson(
    alloc: std.mem.Allocator,
    action: []const u8,
    report: market_migration.InventoryReport,
) ![]u8 {
    var output = std.io.Writer.Allocating.init(alloc);
    errdefer output.deinit();
    var jw = std.json.Stringify{ .writer = &output.writer };
    try beginEnvelope(&jw, action);
    try jw.objectField("schema_count");
    try jw.write(report.schema_count);
    try jw.objectField("series_count");
    try jw.write(report.series_count);
    try jw.objectField("column_count");
    try jw.write(report.column_count);
    try jw.objectField("fanout_values");
    try jw.write(report.fanout_values);
    try jw.objectField("candidate_rows");
    try jw.write(report.candidate_rows);
    try jw.objectField("reconstructable_rows");
    try jw.write(report.reconstructable_rows);
    try jw.objectField("source_bytes");
    try jw.write(report.source_bytes);
    try jw.objectField("estimated_native_bytes");
    try jw.write(report.estimated_native_bytes);
    try jw.objectField("blocked_series");
    try jw.write(report.blocked_series);
    try jw.objectField("blocker_count");
    try jw.write(report.blocker_count);
    try jw.objectField("limitation_count");
    try jw.write(report.limitation_count);
    try jw.objectField("diagnostics");
    try jw.beginArray();
    for (report.diagnostics) |diagnostic| {
        try writeDiagnostic(&jw, diagnostic);
    }
    try jw.endArray();
    try jw.endObject();
    return try output.toOwnedSlice();
}

fn writeDiagnostic(
    jw: *std.json.Stringify,
    diagnostic: market_migration.ReconstructionDiagnostic,
) !void {
    try jw.beginObject();
    try jw.objectField("severity");
    try jw.write(@tagName(diagnostic.severity));
    try jw.objectField("kind");
    try jw.write(@tagName(diagnostic.kind));
    try jw.objectField("metric");
    try jw.write(diagnostic.metric);
    try jw.objectField("labels");
    try jw.write(diagnostic.canonical_labels);
    try jw.objectField("timestamp_ns");
    if (diagnostic.ts_ns) |value| try jw.write(value) else try jw.write(null);
    try jw.objectField("column");
    if (diagnostic.column) |value| try jw.write(value) else try jw.write(null);
    try jw.objectField("missing_columns");
    try jw.beginArray();
    for (diagnostic.missing_columns) |column| try jw.write(column);
    try jw.endArray();
    try jw.objectField("first_bits");
    if (diagnostic.first_bits) |value| try jw.write(value) else try jw.write(null);
    try jw.objectField("second_bits");
    if (diagnostic.second_bits) |value| try jw.write(value) else try jw.write(null);
    try jw.objectField("affected_rows");
    try jw.write(diagnostic.affected_rows);
    try jw.endObject();
}

fn writeMigrationResultJson(
    alloc: std.mem.Allocator,
    action: []const u8,
    phase: market_migration.Phase,
    generation: u64,
    rows_written: u64,
    segments_written: u64,
) ![]u8 {
    var output = std.io.Writer.Allocating.init(alloc);
    errdefer output.deinit();
    var jw = std.json.Stringify{ .writer = &output.writer };
    try beginEnvelope(&jw, action);
    try jw.objectField("phase");
    try jw.write(phase.text());
    try jw.objectField("generation");
    try jw.write(generation);
    try jw.objectField("rows_written");
    try jw.write(rows_written);
    try jw.objectField("segments_written");
    try jw.write(segments_written);
    try jw.endObject();
    return try output.toOwnedSlice();
}

fn writeVerifyJson(
    alloc: std.mem.Allocator,
    phase: market_migration.Phase,
    generation: u64,
    rows_verified: u64,
) ![]u8 {
    var output = std.io.Writer.Allocating.init(alloc);
    errdefer output.deinit();
    var jw = std.json.Stringify{ .writer = &output.writer };
    try beginEnvelope(&jw, "verify");
    try jw.objectField("phase");
    try jw.write(phase.text());
    try jw.objectField("generation");
    try jw.write(generation);
    try jw.objectField("rows_verified");
    try jw.write(rows_verified);
    try jw.objectField("parity");
    try jw.write("exact");
    try jw.endObject();
    return try output.toOwnedSlice();
}

fn writePromotionJson(
    alloc: std.mem.Allocator,
    phase: market_migration.Phase,
    generation: u64,
    checkpoint_ref: []const u8,
    promoted_schemas: usize,
    rows_verified: u64,
) ![]u8 {
    var output = std.io.Writer.Allocating.init(alloc);
    errdefer output.deinit();
    var jw = std.json.Stringify{ .writer = &output.writer };
    try beginEnvelope(&jw, "promote");
    try jw.objectField("phase");
    try jw.write(phase.text());
    try jw.objectField("generation");
    try jw.write(generation);
    try jw.objectField("checkpoint_ref");
    try jw.write(checkpoint_ref);
    try jw.objectField("promoted_schemas");
    try jw.write(promoted_schemas);
    try jw.objectField("rows_verified");
    try jw.write(rows_verified);
    try jw.endObject();
    return try output.toOwnedSlice();
}

fn beginEnvelope(jw: *std.json.Stringify, action: []const u8) !void {
    try jw.beginObject();
    try jw.objectField("schema_version");
    try jw.write(@as(u32, 1));
    try jw.objectField("command");
    try jw.write("market storage");
    try jw.objectField("action");
    try jw.write(action);
}

fn findSchemaIndex(
    schemas: []const market_catalog_mod.MarketSchema,
    metric: []const u8,
) ?usize {
    for (schemas, 0..) |schema, index| {
        if (std.mem.eql(u8, schema.metric, metric)) return index;
    }
    return null;
}

fn findProgress(
    progress: []const market_migration.SeriesProgress,
    key: market_migration.ProgressKey,
) ?market_migration.SeriesProgress {
    for (progress) |entry| {
        if (entry.key.eql(key)) return entry;
    }
    return null;
}

fn ownedSeriesLessThan(_: void, lhs: OwnedFanoutSeries, rhs: OwnedFanoutSeries) bool {
    return market_migration.ProgressKey.lessThan(
        {},
        .{
            .schema_digest = lhs.input.schema_digest,
            .market_series_id = lhs.input.market_series_id,
        },
        .{
            .schema_digest = rhs.input.schema_digest,
            .market_series_id = rhs.input.market_series_id,
        },
    );
}

fn bitsEqual(lhs: []const u64, rhs: []const u64) bool {
    return std.mem.eql(u64, lhs, rhs);
}

fn deinitSchemas(
    alloc: std.mem.Allocator,
    schemas: []market_catalog_mod.MarketSchema,
) void {
    for (schemas) |*schema| schema.deinit(alloc);
    alloc.free(schemas);
}

fn deinitSeries(
    alloc: std.mem.Allocator,
    series: []market_catalog_mod.MarketSeriesIdentity,
) void {
    for (series) |*entry| entry.deinit(alloc);
    alloc.free(series);
}

fn initializeFormat3TestRepository(data_path: []const u8) !void {
    try std.fs.cwd().makePath(data_path);
    var root = try std.fs.cwd().openDir(data_path, .{ .iterate = true });
    defer root.close();
    const legacy_marker = try root.createFile("MANIFEST", .{ .truncate = true });
    legacy_marker.close();
    try root.makePath("objects/info");
    var marker: [16]u8 = undefined;
    @memcpy(marker[0..9], "SYDSTORE1");
    std.mem.writeInt(
        u16,
        marker[9..11],
        cas_mod.primary_repository_format_version,
        .little,
    );
    marker[11] = @intFromEnum(cas_mod.RefBackend.reftable);
    std.mem.writeInt(
        u32,
        marker[12..16],
        cas_mod.default_extent_chunk_bytes,
        .little,
    );
    try root.writeFile(.{
        .sub_path = "objects/info/store-format",
        .data = &marker,
        .flags = .{},
    });
}

fn format3FanoutTestConfig(
    alloc: std.mem.Allocator,
    data_path: []const u8,
) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .always,
        .flush_interval_ms = 60_000,
        .memtable_max_bytes = 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 32 * 1024 * 1024,
        .cas_mode = .dual_write,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .market_storage_mode = .fanout_v1,
        .market_storage_read_mode = .fanout,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn prepareEmptyVerifiedMigration(
    alloc: std.mem.Allocator,
    engine: *engine_mod.Engine,
) !market_migration.MigrationState {
    var schema = try engine.registerMarketSchema(.{
        .metric = "market.promotion.atomicity",
        .ordered_columns = &.{ "price", "size" },
        .required_labels = &.{"symbol"},
    });
    schema.deinit(alloc);

    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    errdefer state.deinit();
    _ = try state.advance(.reconstructing);
    _ = try state.advance(.native_complete);
    _ = try state.advance(.verifying);
    _ = try state.advance(.verified);
    try state.saveAtomically(engine.data_dir);
    return state;
}

test "market storage command parser requires explicit mutating flags" {
    try std.testing.expectEqual(Command.status, try parseCommand(&.{"status"}));
    try std.testing.expectEqual(Command.migrate_dry_run, try parseCommand(&.{ "migrate", "--dry-run" }));
    try std.testing.expectEqualDeep(
        Command{ .migrate_apply = .{ .resume_failed = false } },
        try parseCommand(&.{ "migrate", "--apply" }),
    );
    try std.testing.expectEqualDeep(
        Command{ .migrate_apply = .{ .resume_failed = true } },
        try parseCommand(&.{ "migrate", "--apply", "--resume" }),
    );
    try std.testing.expectEqual(Command.verify, try parseCommand(&.{"verify"}));
    try std.testing.expectEqual(Command.promote_apply, try parseCommand(&.{ "promote", "--apply" }));
    try std.testing.expectError(
        error.InvalidMarketStorageCommand,
        parseCommand(&.{"migrate"}),
    );
    try std.testing.expectError(
        error.InvalidMarketStorageCommand,
        parseCommand(&.{ "migrate", "--resume" }),
    );
    try std.testing.expectError(
        error.InvalidMarketStorageCommand,
        parseCommand(&.{"promote"}),
    );
}

test "promotion checkpoints retry deterministically at every durable boundary" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    inline for (.{
        PromotionFault.after_format_promotion,
        PromotionFault.after_catalog_promotion,
    }) |fault| {
        const data_path = try std.fmt.allocPrint(
            alloc,
            ".zig-cache/tmp/{s}/promotion-{s}",
            .{ tmp.sub_path, @tagName(fault) },
        );
        defer alloc.free(data_path);
        try initializeFormat3TestRepository(data_path);

        var config = try format3FanoutTestConfig(alloc, data_path);
        var engine = try engine_mod.Engine.init(alloc, config);
        defer engine.deinit();
        config = undefined;

        var verified_state = try prepareEmptyVerifiedMigration(alloc, engine);
        const checkpoint_ref = try promotionCheckpointRefAlloc(
            alloc,
            verified_state.generation,
        );
        defer alloc.free(checkpoint_ref);
        verified_state.deinit();

        if (fault == .after_format_promotion) {
            try syncMigrationSnapshot(alloc, engine, "promotion-checkpoint-crash-window");
            try std.testing.expect(try createPromotionCheckpoint(
                alloc,
                engine,
                checkpoint_ref,
            ));
        }

        promotion_fault = fault;
        defer promotion_fault = null;
        const expected_error = switch (fault) {
            .after_format_promotion => error.InjectedAfterMarketFormatPromotion,
            .after_catalog_promotion => error.InjectedAfterMarketCatalogPromotion,
        };
        try std.testing.expectError(
            expected_error,
            promoteApplyAlloc(alloc, engine),
        );

        var interrupted_state = try market_migration.MigrationState.loadOrInit(
            alloc,
            engine.data_dir,
        );
        defer interrupted_state.deinit();
        try std.testing.expectEqual(
            market_migration.Phase.promoting,
            interrupted_state.phase,
        );
        try std.testing.expectEqualStrings(
            checkpoint_ref,
            interrupted_state.checkpoint_ref.?,
        );
        try std.testing.expectEqual(
            cas_mod.current_repository_format_version,
            engine.repository_format.version,
        );
        var interrupted_schema = engine.marketSchema("market.promotion.atomicity").?;
        defer interrupted_schema.deinit(alloc);
        try std.testing.expectEqual(
            if (fault == .after_format_promotion)
                market_catalog_mod.StorageMapping.fanout_v1
            else
                market_catalog_mod.StorageMapping.native_v1,
            interrupted_schema.storage_mapping,
        );

        const completed = try promoteApplyAlloc(alloc, engine);
        defer alloc.free(completed);
        var completed_state = try market_migration.MigrationState.loadOrInit(
            alloc,
            engine.data_dir,
        );
        defer completed_state.deinit();
        try std.testing.expectEqual(
            market_migration.Phase.promoted,
            completed_state.phase,
        );
        var completed_schema = engine.marketSchema("market.promotion.atomicity").?;
        defer completed_schema.deinit(alloc);
        try std.testing.expectEqual(
            market_catalog_mod.StorageMapping.native_v1,
            completed_schema.storage_mapping,
        );

        const refs = try engine.cas.?.listRefs();
        defer {
            for (refs) |*entry| entry.deinit(alloc);
            alloc.free(refs);
        }
        var matching_checkpoints: usize = 0;
        for (refs) |entry| {
            if (std.mem.eql(u8, entry.name, checkpoint_ref)) {
                matching_checkpoints += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), matching_checkpoints);
    }
}

test "inventory JSON preserves exact gap coordinates" {
    const alloc = std.testing.allocator;
    const schema_digest = [_]u8{9} ** 32;
    const labels = "{\"symbol\":\"XYZ\"}";
    const columns = [_][]const u8{ "price", "size" };
    const price = [_]market_migration.FanoutValue{
        market_migration.FanoutValue.fromF64(10, 12.5),
    };
    const size = [_]market_migration.FanoutValue{};
    const inputs = [_]market_migration.FanoutSeriesInput{.{
        .schema_digest = schema_digest,
        .market_series_id = market_identity.seriesId("market.test", labels),
        .metric = "market.test",
        .canonical_labels = labels,
        .ordered_columns = &columns,
        .columns = &.{
            .{ .name = "price", .values = &price },
            .{ .name = "size", .values = &size },
        },
    }};
    var report = try market_migration.inventoryFanout(alloc, &inputs);
    defer report.deinit();
    const json = try writeInventoryJson(alloc, "dry-run", report);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timestamp_ns\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"missing_columns\":[\"size\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocker_count\":1") != null);
}

test "format 3 migration flushes acknowledged tails and preserves write sequence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-storage-ops",
        .{tmp.sub_path},
    );
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);
    {
        var root = try std.fs.cwd().openDir(data_path, .{});
        defer root.close();
        const legacy_marker = try root.createFile("MANIFEST", .{ .truncate = true });
        legacy_marker.close();
        try root.makePath("objects/info");
        var marker: [16]u8 = undefined;
        @memcpy(marker[0..9], "SYDSTORE1");
        std.mem.writeInt(
            u16,
            marker[9..11],
            cas_mod.primary_repository_format_version,
            .little,
        );
        marker[11] = @intFromEnum(cas_mod.RefBackend.reftable);
        std.mem.writeInt(
            u32,
            marker[12..16],
            cas_mod.default_extent_chunk_bytes,
            .little,
        );
        try root.writeFile(.{
            .sub_path = "objects/info/store-format",
            .data = &marker,
            .flags = .{},
        });
    }

    var config = cfg.Config{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .always,
        .flush_interval_ms = 60_000,
        .memtable_max_bytes = 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 32 * 1024 * 1024,
        .cas_mode = .dual_write,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .market_storage_mode = .fanout_v1,
        .market_storage_read_mode = .fanout,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
    var engine = try engine_mod.Engine.init(alloc, config);
    defer engine.deinit();
    config = undefined;

    const values = [_]f64{ 101.25, 7.0 };
    const receipt = try engine.appendMarketRows(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"XYZ\",\"venue\":\"XNYS\"}",
        .ts_ns = 1_700_000_000_000_000_000,
        .values = &values,
    }});
    try std.testing.expectEqual(@as(usize, 1), receipt.accepted_rows);

    const dry_run = try dryRunAlloc(alloc, engine);
    defer alloc.free(dry_run);
    try std.testing.expect(
        std.mem.indexOf(u8, dry_run, "\"reconstructable_rows\":1") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, dry_run, "\"blocker_count\":0") != null,
    );

    const second_values = [_]f64{ 102.5, 8.0 };
    const second_receipt = try engine.appendMarketRows(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"XYZ\",\"venue\":\"XNYS\"}",
        .ts_ns = 1_700_000_000_000_000_001,
        .values = &second_values,
    }});
    try std.testing.expectEqual(@as(usize, 1), second_receipt.accepted_rows);

    const migrated = try migrateApplyAlloc(alloc, engine, false);
    defer alloc.free(migrated);
    try std.testing.expect(
        std.mem.indexOf(u8, migrated, "\"phase\":\"native_complete\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, migrated, "\"rows_written\":2") != null,
    );
    try std.testing.expectEqual(@as(usize, 1), engine.market_manifest.list().len);
    try std.testing.expectEqual(@as(u64, 3), engine.next_market_write_sequence);

    engine.next_market_write_sequence = 1;
    const resumed = try migrateApplyAlloc(alloc, engine, true);
    defer alloc.free(resumed);
    try std.testing.expect(
        std.mem.indexOf(u8, resumed, "\"phase\":\"native_complete\"") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"rows_written\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "\"segments_written\":0") != null);
    try std.testing.expectEqual(@as(u64, 3), engine.next_market_write_sequence);

    const verified = try verifyAlloc(alloc, engine);
    defer alloc.free(verified);
    try std.testing.expect(
        std.mem.indexOf(u8, verified, "\"phase\":\"verified\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, verified, "\"parity\":\"exact\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, verified, "\"rows_verified\":2") != null,
    );
    try std.testing.expectError(
        error.RepositoryFormatMismatch,
        engine.cas.?.exportHeadToLegacy(engine.data_dir),
    );

    const promoted = try promoteApplyAlloc(alloc, engine);
    defer alloc.free(promoted);
    try std.testing.expect(
        std.mem.indexOf(u8, promoted, "\"phase\":\"promoted\"") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, promoted, "\"rows_verified\":2") != null,
    );
    const promoted_again = try promoteApplyAlloc(alloc, engine);
    defer alloc.free(promoted_again);
    try std.testing.expect(
        std.mem.indexOf(u8, promoted_again, "\"phase\":\"promoted\"") != null,
    );

    var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
    defer state.deinit();
    try std.testing.expectEqual(market_migration.Phase.promoted, state.phase);
    try std.testing.expect(state.checkpoint_ref != null);
    try std.testing.expectEqual(
        cas_mod.current_repository_format_version,
        engine.repository_format.version,
    );
    var promoted_schema = engine.marketSchema("market.trade").?;
    defer promoted_schema.deinit(alloc);
    try std.testing.expectEqual(
        market_catalog_mod.StorageMapping.native_v1,
        promoted_schema.storage_mapping,
    );
    try std.testing.expect(engine.metadata.manifest.entries.items.len != 0);

    const corrected_values = [_]f64{ 104.25, 12.0 };
    engine.config.market_storage_mode = .auto;
    engine.config.market_storage_read_mode = .native;
    const correction_receipt = try engine.appendMarketRows(&.{.{
        .metric = "market.trade",
        .labels_json = "{\"symbol\":\"XYZ\",\"venue\":\"XNYS\"}",
        .ts_ns = 1_700_000_000_000_000_000,
        .values = &corrected_values,
    }});
    try std.testing.expectEqual(
        engine_mod.Engine.MarketStorageWriteMode.native_v1,
        correction_receipt.storage_mode,
    );
    try std.testing.expectEqual(@as(usize, 1), correction_receipt.native_rows);
    try std.testing.expectEqual(@as(usize, 0), correction_receipt.fanout_writes);
    try std.testing.expect(try engine.flushAndDrain(5_000));
    try std.testing.expectEqual(@as(u64, 4), engine.next_market_write_sequence);

    var native_result = try engine.queryMarket(.{
        .metric = "market.trade",
        .label_filter_json = "{\"symbol\":\"XYZ\",\"venue\":\"XNYS\"}",
        .start_ts_ns = 1_700_000_000_000_000_000,
        .end_ts_ns = 1_700_000_000_000_000_001,
        .requested_columns = &.{ "price", "size" },
    });
    defer native_result.deinit();
    try std.testing.expectEqual(@as(usize, 2), native_result.rows.len);
    try std.testing.expectEqualSlices(f64, &corrected_values, native_result.rows[0].values);
    try std.testing.expectEqualSlices(f64, &second_values, native_result.rows[1].values);
}

test "engine startup completes an interrupted market promotion" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_path = try std.fmt.allocPrint(
        alloc,
        ".zig-cache/tmp/{s}/market-promotion-recovery",
        .{tmp.sub_path},
    );
    defer alloc.free(data_path);
    try std.fs.cwd().makePath(data_path);
    {
        var root = try std.fs.cwd().openDir(data_path, .{});
        defer root.close();
        const legacy_marker = try root.createFile("MANIFEST", .{ .truncate = true });
        legacy_marker.close();
        try root.makePath("objects/info");
        var marker: [16]u8 = undefined;
        @memcpy(marker[0..9], "SYDSTORE1");
        std.mem.writeInt(
            u16,
            marker[9..11],
            cas_mod.primary_repository_format_version,
            .little,
        );
        marker[11] = @intFromEnum(cas_mod.RefBackend.reftable);
        std.mem.writeInt(
            u32,
            marker[12..16],
            cas_mod.default_extent_chunk_bytes,
            .little,
        );
        try root.writeFile(.{
            .sub_path = "objects/info/store-format",
            .data = &marker,
            .flags = .{},
        });
    }

    {
        var engine = try engine_mod.Engine.init(alloc, .{
            .data_dir = try alloc.dupe(u8, data_path),
            .http_port = 0,
            .fsync = .always,
            .flush_interval_ms = 60_000,
            .memtable_max_bytes = 1024 * 1024,
            .retention_days = 0,
            .auth_token = try alloc.dupe(u8, ""),
            .enable_influx = false,
            .enable_prom = false,
            .mem_limit_bytes = 32 * 1024 * 1024,
            .cas_mode = .dual_write,
            .metadata_read_mode = .legacy,
            .query_compiler_mode = .compiled,
            .market_storage_mode = .fanout_v1,
            .market_storage_read_mode = .fanout,
            .retention_ns = std.StringHashMap(u32).init(alloc),
        });
        defer engine.deinit();

        var state = try market_migration.MigrationState.loadOrInit(alloc, engine.data_dir);
        defer state.deinit();
        _ = try state.advance(.reconstructing);
        _ = try state.advance(.native_complete);
        _ = try state.advance(.verifying);
        _ = try state.advance(.verified);
        const checkpoint_ref = try engine.cas.?.createCheckpoint("promotion-recovery-test") orelse
            return error.MarketMigrationCheckpointMissing;
        defer alloc.free(checkpoint_ref);
        _ = try state.recordCheckpointRef(checkpoint_ref);
        _ = try state.advance(.checkpointed);
        _ = try state.advance(.promoting);
        try state.saveAtomically(engine.data_dir);
    }

    var recovered = try engine_mod.Engine.init(alloc, .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .always,
        .flush_interval_ms = 60_000,
        .memtable_max_bytes = 1024 * 1024,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 32 * 1024 * 1024,
        .cas_mode = .dual_write,
        .metadata_read_mode = .legacy,
        .query_compiler_mode = .compiled,
        .market_storage_mode = .auto,
        .market_storage_read_mode = .auto,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    });
    defer recovered.deinit();

    try std.testing.expectEqual(
        cas_mod.current_repository_format_version,
        recovered.repository_format.version,
    );
    var recovered_schema = recovered.marketSchema("market.trade").?;
    defer recovered_schema.deinit(alloc);
    try std.testing.expectEqual(
        market_catalog_mod.StorageMapping.native_v1,
        recovered_schema.storage_mapping,
    );
    var recovered_state = try market_migration.MigrationState.loadOrInit(
        alloc,
        recovered.data_dir,
    );
    defer recovered_state.deinit();
    try std.testing.expectEqual(market_migration.Phase.promoted, recovered_state.phase);
    try std.testing.expect(recovered_state.checkpoint_ref != null);
    try recovered.cas.?.verifyHeadMatchesLegacyWithNativeMarket(
        recovered.data_dir,
        &recovered.metadata.manifest,
        &recovered.metadata.tags,
        &recovered.metadata.series_catalog,
        &recovered.metadata.metric_catalog,
        &recovered.metadata.market_catalog,
        &recovered.market_manifest,
    );
}
