const std = @import("std");
const market_identity = @import("market_identity.zig");

pub const state_directory = "metadata/market-storage";
pub const state_path = state_directory ++ "/migration-state.json";
const state_file_name = "migration-state.json";
const state_temp_file_name = "migration-state.json.tmp";
const state_format_version: u32 = 1;
const max_state_bytes: usize = 16 * 1024 * 1024;

pub const MarketSeriesId = market_identity.MarketSeriesId;
pub const SchemaDigest = market_identity.SchemaDigest;

/// The durable migration state deliberately stops short of changing catalog
/// mappings or refs. Those transitions are coordinated by the operator layer.
pub const Phase = enum {
    inventory,
    reconstructing,
    native_complete,
    verifying,
    verified,
    checkpointed,
    promoting,
    promoted,
    failed,

    pub fn parse(input: []const u8) ?Phase {
        inline for (std.meta.fields(Phase)) |field| {
            if (std.mem.eql(u8, input, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn text(self: Phase) []const u8 {
        return @tagName(self);
    }
};

pub const ProgressKey = struct {
    schema_digest: SchemaDigest,
    market_series_id: MarketSeriesId,

    pub fn eql(a: ProgressKey, b: ProgressKey) bool {
        return a.market_series_id == b.market_series_id and
            std.mem.eql(u8, &a.schema_digest, &b.schema_digest);
    }

    pub fn lessThan(_: void, a: ProgressKey, b: ProgressKey) bool {
        const digest_order = std.mem.order(u8, &a.schema_digest, &b.schema_digest);
        if (digest_order != .eq) return digest_order == .lt;
        return a.market_series_id < b.market_series_id;
    }
};

pub const SeriesProgress = struct {
    key: ProgressKey,
    last_ts_ns: ?i64 = null,
    rows_reconstructed: u64 = 0,
    completed: bool = false,
};

pub const ResumeCursor = struct {
    phase: Phase,
    progress_index: usize,
    progress: ?SeriesProgress,
};

pub const FailureDiagnostic = struct {
    prior_phase: Phase,
    code: []u8,
    message: []u8,

    pub fn deinit(self: *FailureDiagnostic, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        alloc.free(self.message);
        self.* = undefined;
    }
};

pub const MigrationState = struct {
    alloc: std.mem.Allocator,
    phase: Phase = .inventory,
    generation: u64 = 0,
    checkpoint_ref: ?[]u8 = null,
    failure: ?FailureDiagnostic = null,
    progress: std.ArrayListUnmanaged(SeriesProgress) = .{},

    pub fn init(alloc: std.mem.Allocator) MigrationState {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *MigrationState) void {
        if (self.checkpoint_ref) |value| self.alloc.free(value);
        if (self.failure) |*failure| failure.deinit(self.alloc);
        self.progress.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn loadOrInit(alloc: std.mem.Allocator, data_dir: std.fs.Dir) !MigrationState {
        const bytes = data_dir.readFileAlloc(alloc, state_path, max_state_bytes) catch |err| switch (err) {
            error.FileNotFound => return init(alloc),
            else => return err,
        };
        defer alloc.free(bytes);
        return decode(alloc, bytes);
    }

    pub fn advance(self: *MigrationState, next: Phase) !bool {
        if (self.phase == next) return false;
        if (!validTransition(self.phase, next)) return error.InvalidMarketMigrationTransition;
        if (next == .native_complete and !self.allSeriesComplete()) {
            return error.MarketMigrationProgressIncomplete;
        }
        if (next == .checkpointed and self.checkpoint_ref == null) {
            return error.MarketMigrationCheckpointMissing;
        }
        try incrementGeneration(self);
        self.phase = next;
        return true;
    }

    /// Idempotently records one reconstruction boundary. A resume may repeat
    /// the last successful update, but it may never move time, row count, or
    /// completion backwards.
    pub fn recordProgress(
        self: *MigrationState,
        key: ProgressKey,
        last_ts_ns: ?i64,
        rows_reconstructed: u64,
        completed: bool,
    ) !bool {
        if (self.phase != .reconstructing) return error.InvalidMarketMigrationPhase;
        if (rows_reconstructed != 0 and last_ts_ns == null) {
            return error.InvalidMarketMigrationProgress;
        }

        const index = lowerBoundProgress(self.progress.items, key);
        if (index < self.progress.items.len and self.progress.items[index].key.eql(key)) {
            const previous = self.progress.items[index];
            if (rows_reconstructed < previous.rows_reconstructed or
                timestampRegressed(previous.last_ts_ns, last_ts_ns) or
                (previous.completed and !completed))
            {
                return error.MarketMigrationProgressRegression;
            }
            if (previous.rows_reconstructed == rows_reconstructed and
                previous.last_ts_ns == last_ts_ns and
                previous.completed == completed)
            {
                return false;
            }
            try incrementGeneration(self);
            self.progress.items[index] = .{
                .key = key,
                .last_ts_ns = last_ts_ns,
                .rows_reconstructed = rows_reconstructed,
                .completed = completed,
            };
            return true;
        }

        try self.progress.insert(self.alloc, index, .{
            .key = key,
            .last_ts_ns = last_ts_ns,
            .rows_reconstructed = rows_reconstructed,
            .completed = completed,
        });
        errdefer _ = self.progress.orderedRemove(index);
        try incrementGeneration(self);
        return true;
    }

    pub fn recordCheckpointRef(self: *MigrationState, checkpoint_ref: []const u8) !bool {
        if (self.phase != .verified and self.phase != .checkpointed) {
            return error.InvalidMarketMigrationPhase;
        }
        if (std.mem.trim(u8, checkpoint_ref, " \t\r\n").len != checkpoint_ref.len or
            checkpoint_ref.len == 0)
        {
            return error.InvalidMarketMigrationCheckpoint;
        }
        if (self.checkpoint_ref) |existing| {
            if (std.mem.eql(u8, existing, checkpoint_ref)) return false;
            return error.MarketMigrationCheckpointConflict;
        }
        const copy = try self.alloc.dupe(u8, checkpoint_ref);
        errdefer self.alloc.free(copy);
        try incrementGeneration(self);
        self.checkpoint_ref = copy;
        return true;
    }

    pub fn markFailure(
        self: *MigrationState,
        code: []const u8,
        message: []const u8,
    ) !bool {
        if (self.phase == .promoted) return error.InvalidMarketMigrationPhase;
        try validateFailureText(code, message);
        if (self.phase == .failed) {
            const existing = self.failure orelse return error.InvalidMarketMigrationState;
            if (std.mem.eql(u8, existing.code, code) and
                std.mem.eql(u8, existing.message, message))
            {
                return false;
            }
            return error.MarketMigrationFailureConflict;
        }

        const code_copy = try self.alloc.dupe(u8, code);
        errdefer self.alloc.free(code_copy);
        const message_copy = try self.alloc.dupe(u8, message);
        errdefer self.alloc.free(message_copy);
        try incrementGeneration(self);
        const prior_phase = self.phase;
        self.phase = .failed;
        self.failure = .{
            .prior_phase = prior_phase,
            .code = code_copy,
            .message = message_copy,
        };
        return true;
    }

    pub fn resumeFailure(self: *MigrationState) !void {
        if (self.phase == .promoted or self.phase != .failed) {
            return error.InvalidMarketMigrationPhase;
        }
        const prior_phase = self.failure.?.prior_phase;
        try incrementGeneration(self);
        var failure = self.failure.?;
        self.failure = null;
        self.phase = prior_phase;
        failure.deinit(self.alloc);
    }

    pub fn resumeCursor(self: *const MigrationState) ResumeCursor {
        for (self.progress.items, 0..) |entry, index| {
            if (!entry.completed) {
                return .{
                    .phase = self.phase,
                    .progress_index = index,
                    .progress = entry,
                };
            }
        }
        return .{
            .phase = self.phase,
            .progress_index = self.progress.items.len,
            .progress = null,
        };
    }

    pub fn saveAtomically(self: *const MigrationState, data_dir: std.fs.Dir) !void {
        try validateState(self);

        var root = data_dir;
        try root.makePath(state_directory);
        try syncDir(&root);
        var metadata_dir = try root.openDir("metadata", .{});
        defer metadata_dir.close();
        try syncDir(&metadata_dir);

        var state_dir = try root.openDir(state_directory, .{});
        defer state_dir.close();

        var file = try state_dir.createFile(state_temp_file_name, .{
            .truncate = true,
            .read = true,
        });
        var file_open = true;
        var delete_temp = true;
        defer {
            if (file_open) file.close();
            if (delete_temp) state_dir.deleteFile(state_temp_file_name) catch {};
        }

        var write_buffer: [4096]u8 = undefined;
        var writer_state = file.writer(&write_buffer);
        try writeJson(self, &writer_state.interface);
        try writer_state.end();
        try file.sync();
        file.close();
        file_open = false;

        state_dir.rename(state_temp_file_name, state_file_name) catch |err| switch (err) {
            error.PathAlreadyExists => {
                state_dir.deleteFile(state_file_name) catch {};
                try state_dir.rename(state_temp_file_name, state_file_name);
            },
            else => return err,
        };
        delete_temp = false;
        try syncDir(&state_dir);
    }

    pub fn encodeAlloc(self: *const MigrationState, alloc: std.mem.Allocator) ![]u8 {
        try validateState(self);
        var output = std.io.Writer.Allocating.init(alloc);
        errdefer output.deinit();
        try writeJson(self, &output.writer);
        return output.toOwnedSlice();
    }

    pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !MigrationState {
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMarketMigrationState,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMarketMigrationState;
        const root = parsed.value.object;
        if (root.count() != 6) return error.InvalidMarketMigrationState;

        const version = parseU32(root.get("version") orelse return error.InvalidMarketMigrationState) catch
            return error.InvalidMarketMigrationState;
        if (version != state_format_version) return error.UnsupportedMarketMigrationStateVersion;

        const phase_value = root.get("phase") orelse return error.InvalidMarketMigrationState;
        if (phase_value != .string) return error.InvalidMarketMigrationState;
        const phase = Phase.parse(phase_value.string) orelse return error.InvalidMarketMigrationState;

        const generation = parseU64String(root.get("generation") orelse
            return error.InvalidMarketMigrationState) catch return error.InvalidMarketMigrationState;
        const checkpoint_ref = try parseOptionalOwnedString(
            alloc,
            root.get("checkpoint_ref") orelse return error.InvalidMarketMigrationState,
        );
        var checkpoint_ref_owned = true;
        errdefer if (checkpoint_ref_owned) {
            if (checkpoint_ref) |value| alloc.free(value);
        };
        const failure = try parseOptionalFailure(
            alloc,
            root.get("failure") orelse return error.InvalidMarketMigrationState,
        );
        var failure_owned = true;
        errdefer if (failure_owned) {
            if (failure) |owned_failure| {
                var mutable_failure = owned_failure;
                mutable_failure.deinit(alloc);
            }
        };

        const progress_value = root.get("progress") orelse return error.InvalidMarketMigrationState;
        if (progress_value != .array) return error.InvalidMarketMigrationState;

        var state = MigrationState{
            .alloc = alloc,
            .phase = phase,
            .generation = generation,
            .checkpoint_ref = checkpoint_ref,
            .failure = failure,
        };
        checkpoint_ref_owned = false;
        failure_owned = false;
        errdefer state.deinit();
        try state.progress.ensureTotalCapacity(alloc, progress_value.array.items.len);

        for (progress_value.array.items) |entry_value| {
            const entry = try parseProgress(entry_value);
            if (state.progress.items.len != 0) {
                const previous = state.progress.items[state.progress.items.len - 1];
                if (!ProgressKey.lessThan({}, previous.key, entry.key)) {
                    return error.InvalidMarketMigrationState;
                }
            }
            state.progress.appendAssumeCapacity(entry);
        }
        try validateState(&state);
        return state;
    }

    fn allSeriesComplete(self: *const MigrationState) bool {
        for (self.progress.items) |entry| {
            if (!entry.completed) return false;
        }
        return true;
    }
};

pub const FanoutValue = struct {
    ts_ns: i64,
    value_bits: u64,
    write_sequence: ?u64 = null,

    pub fn fromF64(ts_ns: i64, value: f64) FanoutValue {
        return .{
            .ts_ns = ts_ns,
            .value_bits = @bitCast(value),
        };
    }
};

pub const FanoutColumnInput = struct {
    name: []const u8,
    /// Values with the same timestamp are ordered from oldest to newest
    /// publication. Legacy scalar fanout has no logical-row write sequence, so
    /// reconstruction uses the last published value just as the public fanout
    /// reader does. An explicit write_sequence, when present, takes precedence.
    values: []const FanoutValue,
};

/// Callers adapt scalar fanout series into this immutable view. The adapter
/// owns source discovery; reconstruction owns row atomicity and diagnostics.
pub const FanoutSeriesInput = struct {
    schema_digest: SchemaDigest,
    market_series_id: MarketSeriesId,
    metric: []const u8,
    canonical_labels: []const u8,
    ordered_columns: []const []const u8,
    columns: []const FanoutColumnInput,
    source_bytes: ?u64 = null,
};

pub const DiagnosticSeverity = enum {
    limitation,
    blocker,
};

pub const DiagnosticKind = enum {
    missing_columns,
    conflicting_duplicate_bits,
    inconsistent_write_sequence,
    sequence_history_unavailable,
};

pub const ReconstructionDiagnostic = struct {
    severity: DiagnosticSeverity,
    kind: DiagnosticKind,
    metric: []u8,
    canonical_labels: []u8,
    ts_ns: ?i64 = null,
    column: ?[]u8 = null,
    missing_columns: [][]u8 = &.{},
    first_bits: ?u64 = null,
    second_bits: ?u64 = null,
    affected_rows: u64 = 0,

    pub fn deinit(self: *ReconstructionDiagnostic, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        if (self.column) |value| alloc.free(value);
        for (self.missing_columns) |value| alloc.free(value);
        if (self.missing_columns.len != 0) alloc.free(self.missing_columns);
        self.* = undefined;
    }
};

pub const ReconstructedRow = struct {
    ts_ns: i64,
    write_sequence: ?u64,
    value_bits: []u64,

    pub fn deinit(self: *ReconstructedRow, alloc: std.mem.Allocator) void {
        alloc.free(self.value_bits);
        self.* = undefined;
    }
};

pub const Reconstruction = struct {
    alloc: std.mem.Allocator,
    candidate_rows: u64,
    rows: []ReconstructedRow,
    diagnostics: []ReconstructionDiagnostic,

    pub fn deinit(self: *Reconstruction) void {
        for (self.rows) |*row| row.deinit(self.alloc);
        self.alloc.free(self.rows);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(self.alloc);
        self.alloc.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn blockerCount(self: *const Reconstruction) u64 {
        var count: u64 = 0;
        for (self.diagnostics) |diagnostic| {
            if (diagnostic.severity == .blocker) count += 1;
        }
        return count;
    }
};

const NormalizedValue = struct {
    ts_ns: i64,
    value_bits: u64,
    write_sequence: ?u64,
    conflicted: bool,
};

const IndexedFanoutValue = struct {
    value: FanoutValue,
    publication_ordinal: usize,
};

const NormalizedColumn = struct {
    name: []const u8,
    values: []NormalizedValue,

    fn deinit(self: *NormalizedColumn, alloc: std.mem.Allocator) void {
        alloc.free(self.values);
        self.* = undefined;
    }
};

pub fn reconstructFanoutSeries(
    alloc: std.mem.Allocator,
    input: FanoutSeriesInput,
) !Reconstruction {
    try validateFanoutInput(alloc, input);

    var diagnostics = std.array_list.Managed(ReconstructionDiagnostic).init(alloc);
    errdefer {
        for (diagnostics.items) |*entry| entry.deinit(alloc);
        diagnostics.deinit();
    }

    const normalized = try alloc.alloc(NormalizedColumn, input.ordered_columns.len);
    var normalized_len: usize = 0;
    defer {
        for (normalized[0..normalized_len]) |*column| column.deinit(alloc);
        alloc.free(normalized);
    }

    for (input.ordered_columns) |column_name| {
        const source = findInputColumn(input.columns, column_name).?;
        normalized[normalized_len] = try normalizeColumn(
            alloc,
            input,
            source,
            &diagnostics,
        );
        normalized_len += 1;
    }

    var timestamps = std.array_list.Managed(i64).init(alloc);
    defer timestamps.deinit();
    for (normalized) |column| {
        try timestamps.ensureUnusedCapacity(column.values.len);
        for (column.values) |value| timestamps.appendAssumeCapacity(value.ts_ns);
    }
    std.mem.sort(i64, timestamps.items, {}, comptime std.sort.asc(i64));
    deduplicateSortedTimestamps(&timestamps);

    var rows = std.array_list.Managed(ReconstructedRow).init(alloc);
    errdefer {
        for (rows.items) |*row| row.deinit(alloc);
        rows.deinit();
    }

    var unavailable_sequence_rows: u64 = 0;
    for (timestamps.items) |ts_ns| {
        var missing = std.array_list.Managed([]const u8).init(alloc);
        defer missing.deinit();

        const value_bits = try alloc.alloc(u64, input.ordered_columns.len);
        var keep_values = false;
        defer if (!keep_values) alloc.free(value_bits);

        var row_conflicted = false;
        var row_sequence: ?u64 = null;
        var saw_sequence = false;
        var saw_missing_sequence = false;

        for (normalized, 0..) |column, column_index| {
            const value = findNormalizedValue(column.values, ts_ns) orelse {
                try missing.append(column.name);
                continue;
            };
            value_bits[column_index] = value.value_bits;
            row_conflicted = row_conflicted or value.conflicted;
            if (value.conflicted) continue;
            if (value.write_sequence) |sequence| {
                if (saw_sequence and row_sequence.? != sequence) {
                    row_conflicted = true;
                    try appendDiagnostic(
                        alloc,
                        &diagnostics,
                        input,
                        .blocker,
                        .inconsistent_write_sequence,
                        ts_ns,
                        column.name,
                        &.{},
                        row_sequence,
                        sequence,
                        1,
                    );
                } else {
                    row_sequence = sequence;
                    saw_sequence = true;
                }
            } else {
                saw_missing_sequence = true;
            }
        }

        if (missing.items.len != 0) {
            try appendDiagnostic(
                alloc,
                &diagnostics,
                input,
                .blocker,
                .missing_columns,
                ts_ns,
                null,
                missing.items,
                null,
                null,
                1,
            );
            continue;
        }
        if (saw_sequence and saw_missing_sequence) {
            row_conflicted = true;
            try appendDiagnostic(
                alloc,
                &diagnostics,
                input,
                .blocker,
                .inconsistent_write_sequence,
                ts_ns,
                null,
                &.{},
                row_sequence,
                null,
                1,
            );
        } else if (!saw_sequence) {
            unavailable_sequence_rows += 1;
        }
        if (row_conflicted) continue;

        try rows.append(.{
            .ts_ns = ts_ns,
            .write_sequence = row_sequence,
            .value_bits = value_bits,
        });
        keep_values = true;
    }

    if (unavailable_sequence_rows != 0) {
        try appendDiagnostic(
            alloc,
            &diagnostics,
            input,
            .limitation,
            .sequence_history_unavailable,
            null,
            null,
            &.{},
            null,
            null,
            unavailable_sequence_rows,
        );
    }
    std.mem.sort(
        ReconstructionDiagnostic,
        diagnostics.items,
        {},
        diagnosticLessThan,
    );

    const owned_rows = try rows.toOwnedSlice();
    errdefer {
        for (owned_rows) |*row| row.deinit(alloc);
        alloc.free(owned_rows);
    }
    const owned_diagnostics = try diagnostics.toOwnedSlice();
    return .{
        .alloc = alloc,
        .candidate_rows = @intCast(timestamps.items.len),
        .rows = owned_rows,
        .diagnostics = owned_diagnostics,
    };
}

pub const SeriesInventory = struct {
    key: ProgressKey,
    metric: []u8,
    canonical_labels: []u8,
    column_count: u32,
    fanout_values: u64,
    candidate_rows: u64,
    reconstructable_rows: u64,
    source_bytes: u64,
    estimated_native_bytes: u64,
    blocker_count: u64,
    limitation_count: u64,

    pub fn deinit(self: *SeriesInventory, alloc: std.mem.Allocator) void {
        alloc.free(self.metric);
        alloc.free(self.canonical_labels);
        self.* = undefined;
    }
};

pub const InventoryReport = struct {
    alloc: std.mem.Allocator,
    schema_count: u64,
    series_count: u64,
    column_count: u64,
    fanout_values: u64,
    candidate_rows: u64,
    reconstructable_rows: u64,
    source_bytes: u64,
    estimated_native_bytes: u64,
    blocked_series: u64,
    blocker_count: u64,
    limitation_count: u64,
    series: []SeriesInventory,
    diagnostics: []ReconstructionDiagnostic,

    pub fn deinit(self: *InventoryReport) void {
        for (self.series) |*entry| entry.deinit(self.alloc);
        self.alloc.free(self.series);
        for (self.diagnostics) |*entry| entry.deinit(self.alloc);
        self.alloc.free(self.diagnostics);
        self.* = undefined;
    }
};

pub fn inventoryFanout(
    alloc: std.mem.Allocator,
    inputs: []const FanoutSeriesInput,
) !InventoryReport {
    var series = std.array_list.Managed(SeriesInventory).init(alloc);
    errdefer {
        for (series.items) |*entry| entry.deinit(alloc);
        series.deinit();
    }
    var diagnostics = std.array_list.Managed(ReconstructionDiagnostic).init(alloc);
    errdefer {
        for (diagnostics.items) |*entry| entry.deinit(alloc);
        diagnostics.deinit();
    }

    var report = InventoryReport{
        .alloc = alloc,
        .schema_count = 0,
        .series_count = 0,
        .column_count = 0,
        .fanout_values = 0,
        .candidate_rows = 0,
        .reconstructable_rows = 0,
        .source_bytes = 0,
        .estimated_native_bytes = 0,
        .blocked_series = 0,
        .blocker_count = 0,
        .limitation_count = 0,
        .series = &.{},
        .diagnostics = &.{},
    };

    for (inputs) |input| {
        var reconstruction = try reconstructFanoutSeries(alloc, input);
        defer reconstruction.deinit();

        var fanout_values: u64 = 0;
        for (input.columns) |column| {
            fanout_values = try std.math.add(u64, fanout_values, @intCast(column.values.len));
        }
        const source_bytes = input.source_bytes orelse
            try std.math.mul(u64, fanout_values, 16);
        const row_width = try std.math.add(
            u64,
            16,
            try std.math.mul(u64, @intCast(input.ordered_columns.len), 8),
        );
        const estimated_native_bytes = try std.math.mul(
            u64,
            @intCast(reconstruction.rows.len),
            row_width,
        );

        var blocker_count: u64 = 0;
        var limitation_count: u64 = 0;
        for (reconstruction.diagnostics) |diagnostic| {
            switch (diagnostic.severity) {
                .blocker => blocker_count += 1,
                .limitation => limitation_count += 1,
            }
            var diagnostic_copy = try cloneDiagnostic(alloc, diagnostic);
            errdefer diagnostic_copy.deinit(alloc);
            try diagnostics.append(diagnostic_copy);
        }

        const metric_copy = try alloc.dupe(u8, input.metric);
        errdefer alloc.free(metric_copy);
        const labels_copy = try alloc.dupe(u8, input.canonical_labels);
        errdefer alloc.free(labels_copy);
        try series.append(.{
            .key = .{
                .schema_digest = input.schema_digest,
                .market_series_id = input.market_series_id,
            },
            .metric = metric_copy,
            .canonical_labels = labels_copy,
            .column_count = @intCast(input.ordered_columns.len),
            .fanout_values = fanout_values,
            .candidate_rows = reconstruction.candidate_rows,
            .reconstructable_rows = @intCast(reconstruction.rows.len),
            .source_bytes = source_bytes,
            .estimated_native_bytes = estimated_native_bytes,
            .blocker_count = blocker_count,
            .limitation_count = limitation_count,
        });

        report.column_count = try std.math.add(u64, report.column_count, @intCast(input.ordered_columns.len));
        report.fanout_values = try std.math.add(u64, report.fanout_values, fanout_values);
        report.candidate_rows = try std.math.add(u64, report.candidate_rows, reconstruction.candidate_rows);
        report.reconstructable_rows = try std.math.add(u64, report.reconstructable_rows, @intCast(reconstruction.rows.len));
        report.source_bytes = try std.math.add(u64, report.source_bytes, source_bytes);
        report.estimated_native_bytes = try std.math.add(u64, report.estimated_native_bytes, estimated_native_bytes);
        report.blocker_count = try std.math.add(u64, report.blocker_count, blocker_count);
        report.limitation_count = try std.math.add(u64, report.limitation_count, limitation_count);
        if (blocker_count != 0) report.blocked_series += 1;
    }

    std.mem.sort(SeriesInventory, series.items, {}, seriesInventoryLessThan);
    if (series.items.len > 1) {
        for (series.items[1..], 1..) |entry, index| {
            if (entry.key.eql(series.items[index - 1].key)) {
                return error.DuplicateFanoutMigrationSeries;
            }
        }
    }
    std.mem.sort(ReconstructionDiagnostic, diagnostics.items, {}, diagnosticLessThan);
    report.schema_count = countSchemas(series.items);
    report.series_count = @intCast(series.items.len);
    const owned_series = try series.toOwnedSlice();
    errdefer {
        for (owned_series) |*entry| entry.deinit(alloc);
        alloc.free(owned_series);
    }
    const owned_diagnostics = try diagnostics.toOwnedSlice();
    report.series = owned_series;
    report.diagnostics = owned_diagnostics;
    return report;
}

fn validateFanoutInput(alloc: std.mem.Allocator, input: FanoutSeriesInput) !void {
    market_identity.validateSchemaShape(
        input.metric,
        input.ordered_columns,
        &.{},
    ) catch return error.InvalidFanoutMigrationInput;
    const canonical_labels = market_identity.canonicalizeLabels(
        alloc,
        input.canonical_labels,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFanoutMigrationInput,
    };
    defer alloc.free(canonical_labels);
    if (!std.mem.eql(u8, canonical_labels, input.canonical_labels)) {
        return error.InvalidFanoutMigrationInput;
    }
    if (market_identity.seriesId(input.metric, input.canonical_labels) != input.market_series_id) {
        return error.MarketSeriesIdMismatch;
    }
    if (input.columns.len != input.ordered_columns.len) return error.InvalidFanoutMigrationInput;
    for (input.ordered_columns) |name| {
        var matches: usize = 0;
        for (input.columns) |column| {
            if (std.mem.eql(u8, name, column.name)) matches += 1;
        }
        if (matches != 1) return error.InvalidFanoutMigrationInput;
    }
    for (input.columns) |column| {
        var known = false;
        for (input.ordered_columns) |name| {
            if (std.mem.eql(u8, name, column.name)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidFanoutMigrationInput;
    }
}

fn normalizeColumn(
    alloc: std.mem.Allocator,
    input: FanoutSeriesInput,
    source: FanoutColumnInput,
    diagnostics: *std.array_list.Managed(ReconstructionDiagnostic),
) !NormalizedColumn {
    const sorted = try alloc.alloc(IndexedFanoutValue, source.values.len);
    defer alloc.free(sorted);
    for (source.values, 0..) |value, publication_ordinal| {
        sorted[publication_ordinal] = .{
            .value = value,
            .publication_ordinal = publication_ordinal,
        };
    }
    std.mem.sort(IndexedFanoutValue, sorted, {}, indexedFanoutValueLessThan);

    var normalized = std.array_list.Managed(NormalizedValue).init(alloc);
    errdefer normalized.deinit();
    var cursor: usize = 0;
    while (cursor < sorted.len) {
        const start = cursor;
        const ts_ns = sorted[cursor].value.ts_ns;
        while (cursor < sorted.len and sorted[cursor].value.ts_ns == ts_ns) : (cursor += 1) {}
        const group = sorted[start..cursor];
        var conflicted = false;
        var saw_sequence = false;
        var saw_missing_sequence = false;
        var highest_sequence: ?u64 = null;
        for (group) |indexed| {
            const candidate = indexed.value;
            if (candidate.write_sequence) |sequence| {
                saw_sequence = true;
                if (highest_sequence == null or sequence > highest_sequence.?) {
                    highest_sequence = sequence;
                }
            } else {
                saw_missing_sequence = true;
            }
        }

        var selected_bits = group[0].value.value_bits;
        if (saw_sequence and saw_missing_sequence) {
            try appendDiagnostic(
                alloc,
                diagnostics,
                input,
                .blocker,
                .inconsistent_write_sequence,
                ts_ns,
                source.name,
                &.{},
                highest_sequence,
                null,
                1,
            );
            conflicted = true;
            highest_sequence = null;
        } else if (saw_sequence) {
            var winner_found = false;
            for (group) |indexed| {
                const candidate = indexed.value;
                if (candidate.write_sequence.? != highest_sequence.?) continue;
                if (!winner_found) {
                    selected_bits = candidate.value_bits;
                    winner_found = true;
                } else if (candidate.value_bits != selected_bits) {
                    try appendDiagnostic(
                        alloc,
                        diagnostics,
                        input,
                        .blocker,
                        .conflicting_duplicate_bits,
                        ts_ns,
                        source.name,
                        &.{},
                        selected_bits,
                        candidate.value_bits,
                        1,
                    );
                    conflicted = true;
                    break;
                }
            }
        } else {
            selected_bits = group[group.len - 1].value.value_bits;
        }
        try normalized.append(.{
            .ts_ns = ts_ns,
            .value_bits = selected_bits,
            .write_sequence = highest_sequence,
            .conflicted = conflicted,
        });
    }
    return .{
        .name = source.name,
        .values = try normalized.toOwnedSlice(),
    };
}

fn findInputColumn(columns: []const FanoutColumnInput, name: []const u8) ?FanoutColumnInput {
    for (columns) |column| {
        if (std.mem.eql(u8, column.name, name)) return column;
    }
    return null;
}

fn findNormalizedValue(values: []const NormalizedValue, ts_ns: i64) ?NormalizedValue {
    var left: usize = 0;
    var right: usize = values.len;
    while (left < right) {
        const middle = left + (right - left) / 2;
        if (values[middle].ts_ns < ts_ns) {
            left = middle + 1;
        } else {
            right = middle;
        }
    }
    if (left < values.len and values[left].ts_ns == ts_ns) return values[left];
    return null;
}

fn deduplicateSortedTimestamps(timestamps: *std.array_list.Managed(i64)) void {
    if (timestamps.items.len < 2) return;
    var write_index: usize = 1;
    for (timestamps.items[1..]) |timestamp| {
        if (timestamp == timestamps.items[write_index - 1]) continue;
        timestamps.items[write_index] = timestamp;
        write_index += 1;
    }
    timestamps.items.len = write_index;
}

fn appendDiagnostic(
    alloc: std.mem.Allocator,
    diagnostics: *std.array_list.Managed(ReconstructionDiagnostic),
    input: FanoutSeriesInput,
    severity: DiagnosticSeverity,
    kind: DiagnosticKind,
    ts_ns: ?i64,
    column: ?[]const u8,
    missing_columns: []const []const u8,
    first_bits: ?u64,
    second_bits: ?u64,
    affected_rows: u64,
) !void {
    const metric = try alloc.dupe(u8, input.metric);
    errdefer alloc.free(metric);
    const labels = try alloc.dupe(u8, input.canonical_labels);
    errdefer alloc.free(labels);
    const column_copy = if (column) |value| try alloc.dupe(u8, value) else null;
    errdefer if (column_copy) |value| alloc.free(value);
    const missing_copy = try cloneStrings(alloc, missing_columns);
    errdefer freeStrings(alloc, missing_copy);
    try diagnostics.append(.{
        .severity = severity,
        .kind = kind,
        .metric = metric,
        .canonical_labels = labels,
        .ts_ns = ts_ns,
        .column = column_copy,
        .missing_columns = missing_copy,
        .first_bits = first_bits,
        .second_bits = second_bits,
        .affected_rows = affected_rows,
    });
}

fn cloneDiagnostic(
    alloc: std.mem.Allocator,
    source: ReconstructionDiagnostic,
) !ReconstructionDiagnostic {
    const metric = try alloc.dupe(u8, source.metric);
    errdefer alloc.free(metric);
    const labels = try alloc.dupe(u8, source.canonical_labels);
    errdefer alloc.free(labels);
    const column = if (source.column) |value| try alloc.dupe(u8, value) else null;
    errdefer if (column) |value| alloc.free(value);
    return .{
        .severity = source.severity,
        .kind = source.kind,
        .metric = metric,
        .canonical_labels = labels,
        .ts_ns = source.ts_ns,
        .column = column,
        .missing_columns = try cloneStrings(alloc, source.missing_columns),
        .first_bits = source.first_bits,
        .second_bits = source.second_bits,
        .affected_rows = source.affected_rows,
    };
}

fn cloneStrings(alloc: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    if (values.len == 0) return &.{};
    const result = try alloc.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStrings(alloc: std.mem.Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len != 0) alloc.free(values);
}

fn countSchemas(series: []const SeriesInventory) u64 {
    var count: u64 = 0;
    var previous: ?SchemaDigest = null;
    for (series) |entry| {
        if (previous == null or !std.mem.eql(u8, &previous.?, &entry.key.schema_digest)) {
            count += 1;
            previous = entry.key.schema_digest;
        }
    }
    return count;
}

fn seriesInventoryLessThan(_: void, a: SeriesInventory, b: SeriesInventory) bool {
    return ProgressKey.lessThan({}, a.key, b.key);
}

fn indexedFanoutValueLessThan(_: void, a: IndexedFanoutValue, b: IndexedFanoutValue) bool {
    if (a.value.ts_ns != b.value.ts_ns) return a.value.ts_ns < b.value.ts_ns;
    return a.publication_ordinal < b.publication_ordinal;
}

fn diagnosticLessThan(_: void, a: ReconstructionDiagnostic, b: ReconstructionDiagnostic) bool {
    const metric_order = std.mem.order(u8, a.metric, b.metric);
    if (metric_order != .eq) return metric_order == .lt;
    const labels_order = std.mem.order(u8, a.canonical_labels, b.canonical_labels);
    if (labels_order != .eq) return labels_order == .lt;
    const timestamp_order = optionalI64Order(a.ts_ns, b.ts_ns);
    if (timestamp_order != .eq) return timestamp_order == .lt;
    if (@intFromEnum(a.kind) != @intFromEnum(b.kind)) {
        return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    }
    return std.mem.order(
        u8,
        a.column orelse "",
        b.column orelse "",
    ) == .lt;
}

fn optionalI64Order(a: ?i64, b: ?i64) std.math.Order {
    if (a == null and b == null) return .eq;
    if (a == null) return .lt;
    if (b == null) return .gt;
    return std.math.order(a.?, b.?);
}

fn validTransition(current: Phase, next: Phase) bool {
    return switch (current) {
        .inventory => next == .reconstructing,
        .reconstructing => next == .native_complete,
        .native_complete => next == .verifying,
        .verifying => next == .verified,
        .verified => next == .checkpointed,
        .checkpointed => next == .promoting,
        .promoting => next == .promoted,
        .promoted => false,
        .failed => false,
    };
}

fn lowerBoundProgress(entries: []const SeriesProgress, key: ProgressKey) usize {
    var left: usize = 0;
    var right: usize = entries.len;
    while (left < right) {
        const middle = left + (right - left) / 2;
        if (ProgressKey.lessThan({}, entries[middle].key, key)) {
            left = middle + 1;
        } else {
            right = middle;
        }
    }
    return left;
}

fn timestampRegressed(previous: ?i64, next: ?i64) bool {
    if (previous == null) return false;
    if (next == null) return true;
    return next.? < previous.?;
}

fn incrementGeneration(state: *MigrationState) !void {
    state.generation = try std.math.add(u64, state.generation, 1);
}

fn validateState(state: *const MigrationState) !void {
    const effective_phase = if (state.phase == .failed) blk: {
        const failure = state.failure orelse return error.InvalidMarketMigrationState;
        if (failure.prior_phase == .failed or failure.prior_phase == .promoted) {
            return error.InvalidMarketMigrationState;
        }
        try validateFailureText(failure.code, failure.message);
        break :blk failure.prior_phase;
    } else blk: {
        if (state.failure != null) return error.InvalidMarketMigrationState;
        break :blk state.phase;
    };

    if ((effective_phase == .checkpointed or
        effective_phase == .promoting or
        effective_phase == .promoted) and state.checkpoint_ref == null)
    {
        return error.InvalidMarketMigrationState;
    }
    for (state.progress.items, 0..) |entry, index| {
        if (entry.rows_reconstructed != 0 and entry.last_ts_ns == null) {
            return error.InvalidMarketMigrationState;
        }
        if (index != 0 and !ProgressKey.lessThan({}, state.progress.items[index - 1].key, entry.key)) {
            return error.InvalidMarketMigrationState;
        }
    }
    if (@intFromEnum(effective_phase) >= @intFromEnum(Phase.native_complete) and
        !state.allSeriesComplete())
    {
        return error.InvalidMarketMigrationState;
    }
}

fn writeJson(state: *const MigrationState, writer: *std.io.Writer) !void {
    var json = std.json.Stringify{ .writer = writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(state_format_version);
    try json.objectField("phase");
    try json.write(state.phase.text());
    try json.objectField("generation");
    var generation_buffer: [20]u8 = undefined;
    try json.write(try std.fmt.bufPrint(&generation_buffer, "{d}", .{state.generation}));
    try json.objectField("checkpoint_ref");
    if (state.checkpoint_ref) |value| try json.write(value) else try json.write(null);
    try json.objectField("failure");
    if (state.failure) |failure| {
        try json.beginObject();
        try json.objectField("prior_phase");
        try json.write(failure.prior_phase.text());
        try json.objectField("code");
        try json.write(failure.code);
        try json.objectField("message");
        try json.write(failure.message);
        try json.endObject();
    } else {
        try json.write(null);
    }
    try json.objectField("progress");
    try json.beginArray();
    for (state.progress.items) |entry| {
        try json.beginObject();
        try json.objectField("schema_digest");
        const digest_hex = market_identity.digestToHex(entry.key.schema_digest);
        try json.write(&digest_hex);
        try json.objectField("market_series_id");
        var series_buffer: [16]u8 = undefined;
        _ = try std.fmt.bufPrint(&series_buffer, "{x:0>16}", .{entry.key.market_series_id});
        try json.write(&series_buffer);
        try json.objectField("last_ts_ns");
        if (entry.last_ts_ns) |value| try json.write(value) else try json.write(null);
        try json.objectField("rows_reconstructed");
        var rows_buffer: [20]u8 = undefined;
        try json.write(try std.fmt.bufPrint(&rows_buffer, "{d}", .{entry.rows_reconstructed}));
        try json.objectField("completed");
        try json.write(entry.completed);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn parseProgress(value: std.json.Value) !SeriesProgress {
    if (value != .object or value.object.count() != 5) {
        return error.InvalidMarketMigrationState;
    }
    const digest_value = value.object.get("schema_digest") orelse
        return error.InvalidMarketMigrationState;
    if (digest_value != .string) return error.InvalidMarketMigrationState;
    const digest = market_identity.digestFromHex(digest_value.string) catch
        return error.InvalidMarketMigrationState;

    const series_value = value.object.get("market_series_id") orelse
        return error.InvalidMarketMigrationState;
    if (series_value != .string or series_value.string.len != 16) {
        return error.InvalidMarketMigrationState;
    }
    const market_series_id = std.fmt.parseInt(u64, series_value.string, 16) catch
        return error.InvalidMarketMigrationState;

    const last_ts_ns = parseOptionalI64(value.object.get("last_ts_ns") orelse
        return error.InvalidMarketMigrationState) catch return error.InvalidMarketMigrationState;
    const rows_reconstructed = parseU64String(value.object.get("rows_reconstructed") orelse
        return error.InvalidMarketMigrationState) catch return error.InvalidMarketMigrationState;
    const completed_value = value.object.get("completed") orelse
        return error.InvalidMarketMigrationState;
    if (completed_value != .bool) return error.InvalidMarketMigrationState;

    return .{
        .key = .{
            .schema_digest = digest,
            .market_series_id = market_series_id,
        },
        .last_ts_ns = last_ts_ns,
        .rows_reconstructed = rows_reconstructed,
        .completed = completed_value.bool,
    };
}

fn parseU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse
            error.InvalidMarketMigrationState,
        else => error.InvalidMarketMigrationState,
    };
}

fn parseU64String(value: std.json.Value) !u64 {
    if (value != .string or value.string.len == 0) {
        return error.InvalidMarketMigrationState;
    }
    return std.fmt.parseInt(u64, value.string, 10) catch
        error.InvalidMarketMigrationState;
}

fn parseOptionalI64(value: std.json.Value) !?i64 {
    return switch (value) {
        .null => null,
        .integer => |integer| integer,
        else => error.InvalidMarketMigrationState,
    };
}

fn parseOptionalOwnedString(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) !?[]u8 {
    return switch (value) {
        .null => null,
        .string => |text| if (text.len == 0)
            error.InvalidMarketMigrationState
        else
            try alloc.dupe(u8, text),
        else => error.InvalidMarketMigrationState,
    };
}

fn parseOptionalFailure(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) !?FailureDiagnostic {
    if (value == .null) return null;
    if (value != .object or value.object.count() != 3) {
        return error.InvalidMarketMigrationState;
    }
    const prior_phase_value = value.object.get("prior_phase") orelse
        return error.InvalidMarketMigrationState;
    if (prior_phase_value != .string) return error.InvalidMarketMigrationState;
    const prior_phase = Phase.parse(prior_phase_value.string) orelse
        return error.InvalidMarketMigrationState;
    if (prior_phase == .failed or prior_phase == .promoted) {
        return error.InvalidMarketMigrationState;
    }
    const code_value = value.object.get("code") orelse
        return error.InvalidMarketMigrationState;
    const message_value = value.object.get("message") orelse
        return error.InvalidMarketMigrationState;
    if (code_value != .string or message_value != .string) {
        return error.InvalidMarketMigrationState;
    }
    validateFailureText(code_value.string, message_value.string) catch
        return error.InvalidMarketMigrationState;

    const code = try alloc.dupe(u8, code_value.string);
    errdefer alloc.free(code);
    return .{
        .prior_phase = prior_phase,
        .code = code,
        .message = try alloc.dupe(u8, message_value.string),
    };
}

fn validateFailureText(code: []const u8, message: []const u8) !void {
    if (code.len == 0 or message.len == 0 or
        std.mem.trim(u8, message, " \t\r\n").len != message.len)
    {
        return error.InvalidMarketMigrationFailure;
    }
    for (code) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '_')) {
            return error.InvalidMarketMigrationFailure;
        }
    }
}

fn syncDir(dir: *std.fs.Dir) !void {
    var sync_dir = try dir.*.openDir(".", .{ .iterate = true });
    defer sync_dir.close();
    try std.posix.fsync(sync_dir.fd);
}

fn checkReconstructionAllocationFailures(alloc: std.mem.Allocator) !void {
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        FanoutValue.fromF64(10, 100),
        FanoutValue.fromF64(20, 101),
        FanoutValue.fromF64(20, 102),
    };
    const size = [_]FanoutValue{
        FanoutValue.fromF64(10, 5),
        FanoutValue.fromF64(30, 7),
    };
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };
    var result = try reconstructFanoutSeries(alloc, .{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    });
    defer result.deinit();
}

fn checkInventoryAllocationFailures(alloc: std.mem.Allocator) !void {
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{FanoutValue.fromF64(10, 100)};
    const size = [_]FanoutValue{FanoutValue.fromF64(10, 5)};
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };
    var report = try inventoryFanout(alloc, &.{.{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    }});
    defer report.deinit();
}

fn checkCheckpointDecodeAllocationFailures(alloc: std.mem.Allocator) !void {
    const checkpoint =
        \\{"version":1,"phase":"failed","generation":"3","checkpoint_ref":null,"failure":{"prior_phase":"reconstructing","code":"segment_write_failed","message":"native segment write failed"},"progress":[{"schema_digest":"1111111111111111111111111111111111111111111111111111111111111111","market_series_id":"ffffffffffffffff","last_ts_ns":10,"rows_reconstructed":"1","completed":false}]}
    ;
    var state = try MigrationState.decode(alloc, checkpoint);
    defer state.deinit();
}

fn checkFailureAllocationFailures(alloc: std.mem.Allocator) !void {
    var state = MigrationState.init(alloc);
    defer state.deinit();
    _ = try state.advance(.reconstructing);
    _ = try state.markFailure("segment_write_failed", "native segment write failed");
}

test "fanout reconstruction forms complete rows and coalesces exact duplicate bits" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const columns = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &columns, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        .{ .ts_ns = 20, .value_bits = @bitCast(@as(f64, 101.0)), .write_sequence = 2 },
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 100.0)), .write_sequence = 1 },
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 100.0)), .write_sequence = 2 },
    };
    const size = [_]FanoutValue{
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 3.0)), .write_sequence = 2 },
        .{ .ts_ns = 20, .value_bits = @bitCast(@as(f64, 4.0)), .write_sequence = 2 },
    };
    const fanout_columns = [_]FanoutColumnInput{
        .{ .name = "size", .values = &size },
        .{ .name = "price", .values = &price },
    };

    var result = try reconstructFanoutSeries(alloc, .{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &columns,
        .columns = &fanout_columns,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.candidate_rows);
    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(i64, 10), result.rows[0].ts_ns);
    try std.testing.expectEqual(@as(?u64, 2), result.rows[0].write_sequence);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 100.0))), result.rows[0].value_bits[0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3.0))), result.rows[0].value_bits[1]);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "fanout reconstruction reports exact gaps and sequence limitation" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        FanoutValue.fromF64(10, 100.0),
        FanoutValue.fromF64(20, 101.0),
        FanoutValue.fromF64(20, 102.0),
        FanoutValue.fromF64(30, 103.0),
    };
    const size = [_]FanoutValue{
        FanoutValue.fromF64(10, 5.0),
        FanoutValue.fromF64(20, 6.0),
    };
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };

    var result = try reconstructFanoutSeries(alloc, .{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(u64, 1), result.blockerCount());
    try std.testing.expectEqual(@as(i64, 20), result.rows[1].ts_ns);
    try std.testing.expectEqual(
        @as(u64, @bitCast(@as(f64, 102.0))),
        result.rows[1].value_bits[0],
    );
    var found_gap = false;
    var found_sequence_limitation = false;
    for (result.diagnostics) |diagnostic| switch (diagnostic.kind) {
        .missing_columns => {
            found_gap = true;
            try std.testing.expectEqualStrings(metric, diagnostic.metric);
            try std.testing.expectEqualStrings(labels, diagnostic.canonical_labels);
            try std.testing.expectEqual(@as(?i64, 30), diagnostic.ts_ns);
            try std.testing.expectEqual(@as(usize, 1), diagnostic.missing_columns.len);
            try std.testing.expectEqualStrings("size", diagnostic.missing_columns[0]);
        },
        .conflicting_duplicate_bits => {},
        .sequence_history_unavailable => {
            found_sequence_limitation = true;
            try std.testing.expectEqual(.limitation, diagnostic.severity);
            try std.testing.expectEqual(@as(u64, 2), diagnostic.affected_rows);
        },
        .inconsistent_write_sequence => {},
    };
    try std.testing.expect(found_gap);
    try std.testing.expect(found_sequence_limitation);
}

test "fanout reconstruction deterministically preserves last-published corrections" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        FanoutValue.fromF64(20, 200),
        FanoutValue.fromF64(10, 100),
        FanoutValue.fromF64(20, 201),
        FanoutValue.fromF64(10, 101),
    };
    const size = [_]FanoutValue{
        FanoutValue.fromF64(10, 5),
        FanoutValue.fromF64(20, 7),
        FanoutValue.fromF64(10, 6),
        FanoutValue.fromF64(20, 8),
    };
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };
    const input = FanoutSeriesInput{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    };

    var first = try reconstructFanoutSeries(alloc, input);
    defer first.deinit();
    var second = try reconstructFanoutSeries(alloc, input);
    defer second.deinit();

    try std.testing.expectEqual(@as(u64, 0), first.blockerCount());
    try std.testing.expectEqual(@as(usize, 2), first.rows.len);
    try std.testing.expectEqual(@as(usize, first.rows.len), second.rows.len);
    const expected = [_][2]u64{
        .{ @bitCast(@as(f64, 101)), @bitCast(@as(f64, 6)) },
        .{ @bitCast(@as(f64, 201)), @bitCast(@as(f64, 8)) },
    };
    for (first.rows, second.rows, expected, 0..) |first_row, second_row, row_bits, index| {
        try std.testing.expectEqual(@as(i64, @intCast((index + 1) * 10)), first_row.ts_ns);
        try std.testing.expectEqual(first_row.ts_ns, second_row.ts_ns);
        try std.testing.expectEqualSlices(u64, &row_bits, first_row.value_bits);
        try std.testing.expectEqualSlices(u64, first_row.value_bits, second_row.value_bits);
        try std.testing.expectEqual(@as(?u64, null), first_row.write_sequence);
    }
    try std.testing.expectEqual(@as(usize, 1), first.diagnostics.len);
    try std.testing.expectEqual(
        DiagnosticKind.sequence_history_unavailable,
        first.diagnostics[0].kind,
    );
    try std.testing.expectEqual(@as(u64, 2), first.diagnostics[0].affected_rows);
}

test "fanout reconstruction selects the highest complete write sequence" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 100)), .write_sequence = 1 },
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 101)), .write_sequence = 2 },
    };
    const size = [_]FanoutValue{
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 5)), .write_sequence = 1 },
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 6)), .write_sequence = 2 },
    };
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };

    var result = try reconstructFanoutSeries(alloc, .{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(?u64, 2), result.rows[0].write_sequence);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 101))), result.rows[0].value_bits[0]);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 6))), result.rows[0].value_bits[1]);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "fanout reconstruction rejects equal-winning bits and mixed sequence provenance" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 101)), .write_sequence = 2 },
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 102)), .write_sequence = 2 },
        .{ .ts_ns = 20, .value_bits = @bitCast(@as(f64, 103)), .write_sequence = 3 },
        FanoutValue.fromF64(20, 103),
    };
    const size = [_]FanoutValue{
        .{ .ts_ns = 10, .value_bits = @bitCast(@as(f64, 5)), .write_sequence = 2 },
        .{ .ts_ns = 20, .value_bits = @bitCast(@as(f64, 6)), .write_sequence = 3 },
    };
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };

    var result = try reconstructFanoutSeries(alloc, .{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(u64, 2), result.blockerCount());
    var found_equal_winner_conflict = false;
    var found_mixed_sequence = false;
    for (result.diagnostics) |diagnostic| {
        if (diagnostic.kind == .conflicting_duplicate_bits and diagnostic.ts_ns == 10) {
            found_equal_winner_conflict = true;
        }
        if (diagnostic.kind == .inconsistent_write_sequence and diagnostic.ts_ns == 20) {
            found_mixed_sequence = true;
        }
    }
    try std.testing.expect(found_equal_winner_conflict);
    try std.testing.expect(found_mixed_sequence);
}

test "fanout inventory reports deterministic counts bytes and blockers" {
    const alloc = std.testing.allocator;
    const labels = "{\"symbol\":\"AAPL\",\"venue\":\"XNAS\"}";
    const metric = "market.trade";
    const ordered = [_][]const u8{ "price", "size" };
    const digest = market_identity.schemaDigest(metric, &ordered, &.{ "symbol", "venue" }, "fanout_v1");
    const price = [_]FanoutValue{ FanoutValue.fromF64(10, 100), FanoutValue.fromF64(20, 101) };
    const size = [_]FanoutValue{FanoutValue.fromF64(10, 5)};
    const columns = [_]FanoutColumnInput{
        .{ .name = "price", .values = &price },
        .{ .name = "size", .values = &size },
    };

    var report = try inventoryFanout(alloc, &.{.{
        .schema_digest = digest,
        .market_series_id = market_identity.seriesId(metric, labels),
        .metric = metric,
        .canonical_labels = labels,
        .ordered_columns = &ordered,
        .columns = &columns,
        .source_bytes = 777,
    }});
    defer report.deinit();

    try std.testing.expectEqual(@as(u64, 1), report.schema_count);
    try std.testing.expectEqual(@as(u64, 1), report.series_count);
    try std.testing.expectEqual(@as(u64, 2), report.column_count);
    try std.testing.expectEqual(@as(u64, 3), report.fanout_values);
    try std.testing.expectEqual(@as(u64, 2), report.candidate_rows);
    try std.testing.expectEqual(@as(u64, 1), report.reconstructable_rows);
    try std.testing.expectEqual(@as(u64, 777), report.source_bytes);
    try std.testing.expectEqual(@as(u64, 32), report.estimated_native_bytes);
    try std.testing.expectEqual(@as(u64, 1), report.blocked_series);
}

test "fanout migration report builders release partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkReconstructionAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkInventoryAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCheckpointDecodeAllocationFailures,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkFailureAllocationFailures,
        .{},
    );
}

test "migration checkpoint is deterministic durable and resumes idempotently" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var state = MigrationState.init(alloc);
    defer state.deinit();
    try std.testing.expect(try state.advance(.reconstructing));

    const key_b = ProgressKey{ .schema_digest = @splat(0x22), .market_series_id = 9 };
    const key_a = ProgressKey{ .schema_digest = @splat(0x11), .market_series_id = std.math.maxInt(u64) };
    try std.testing.expect(try state.recordProgress(key_b, 20, 2, false));
    try std.testing.expect(try state.recordProgress(key_a, 10, 1, true));
    try std.testing.expect(!(try state.recordProgress(key_a, 10, 1, true)));
    try std.testing.expectError(
        error.MarketMigrationProgressRegression,
        state.recordProgress(key_b, 19, 2, false),
    );

    const encoded_a = try state.encodeAlloc(alloc);
    defer alloc.free(encoded_a);
    const encoded_b = try state.encodeAlloc(alloc);
    defer alloc.free(encoded_b);
    try std.testing.expectEqualStrings(encoded_a, encoded_b);
    try std.testing.expect(std.mem.indexOf(u8, encoded_a, "ffffffffffffffff") != null);

    try state.saveAtomically(tmp.dir);
    var resumed = try MigrationState.loadOrInit(alloc, tmp.dir);
    defer resumed.deinit();
    try std.testing.expectEqual(state.generation, resumed.generation);
    const cursor = resumed.resumeCursor();
    try std.testing.expectEqual(@as(usize, 1), cursor.progress_index);
    try std.testing.expect(cursor.progress != null);
    try std.testing.expect(cursor.progress.?.key.eql(key_b));
    try std.testing.expect(!(try resumed.recordProgress(key_b, 20, 2, false)));
    try std.testing.expect(try resumed.recordProgress(key_b, 20, 2, true));
    try std.testing.expect(try resumed.advance(.native_complete));
    try std.testing.expect(try resumed.advance(.verifying));
    try std.testing.expect(try resumed.advance(.verified));
    try std.testing.expect(try resumed.recordCheckpointRef("refs/checkpoints/pre-native-promotion"));
    try std.testing.expect(!(try resumed.recordCheckpointRef("refs/checkpoints/pre-native-promotion")));
    try std.testing.expect(try resumed.advance(.checkpointed));
}

test "migration failure round trips idempotently and resumes its prior phase" {
    const alloc = std.testing.allocator;
    var state = MigrationState.init(alloc);
    defer state.deinit();
    try std.testing.expect(try state.advance(.reconstructing));
    const key = ProgressKey{ .schema_digest = @splat(0x44), .market_series_id = 44 };
    try std.testing.expect(try state.recordProgress(key, 40, 4, false));

    try std.testing.expect(try state.markFailure(
        "segment_write_failed",
        "native segment write failed",
    ));
    const failed_generation = state.generation;
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqual(Phase.reconstructing, state.failure.?.prior_phase);
    try std.testing.expect(!(try state.markFailure(
        "segment_write_failed",
        "native segment write failed",
    )));
    try std.testing.expectEqual(failed_generation, state.generation);
    try std.testing.expectError(
        error.MarketMigrationFailureConflict,
        state.markFailure("manifest_write_failed", "native manifest write failed"),
    );

    const encoded = try state.encodeAlloc(alloc);
    defer alloc.free(encoded);
    var decoded = try MigrationState.decode(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(Phase.failed, decoded.phase);
    try std.testing.expectEqualStrings("segment_write_failed", decoded.failure.?.code);
    try std.testing.expectEqualStrings("native segment write failed", decoded.failure.?.message);
    try std.testing.expectEqual(@as(usize, 1), decoded.progress.items.len);
    try std.testing.expect(decoded.progress.items[0].key.eql(key));

    try decoded.resumeFailure();
    try std.testing.expectEqual(Phase.reconstructing, decoded.phase);
    try std.testing.expect(decoded.failure == null);
    try std.testing.expectEqual(failed_generation + 1, decoded.generation);
    try std.testing.expectEqual(@as(u64, 4), decoded.progress.items[0].rows_reconstructed);
    try std.testing.expectError(error.InvalidMarketMigrationPhase, decoded.resumeFailure());
}

test "migration checkpoint rejects corrupt state and illegal transitions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(state_directory);
    try tmp.dir.writeFile(.{
        .sub_path = state_path,
        .data = "{\"version\":1,\"phase\":\"promoted\",\"generation\":\"4\",\"checkpoint_ref\":null,\"failure\":null,\"progress\":[]}",
    });
    try std.testing.expectError(
        error.InvalidMarketMigrationState,
        MigrationState.loadOrInit(alloc, tmp.dir),
    );

    var state = MigrationState.init(alloc);
    defer state.deinit();
    try std.testing.expectError(
        error.InvalidMarketMigrationTransition,
        state.advance(.verified),
    );
    try std.testing.expect(try state.advance(.reconstructing));
    try std.testing.expectError(
        error.MarketMigrationProgressIncomplete,
        blk: {
            _ = try state.recordProgress(.{
                .schema_digest = @splat(0x33),
                .market_series_id = 3,
            }, 10, 1, false);
            break :blk state.advance(.native_complete);
        },
    );

    const corrupt_failure =
        \\{"version":1,"phase":"failed","generation":"4","checkpoint_ref":null,"failure":{"prior_phase":"promoted","code":"bad_state","message":"bad prior phase"},"progress":[]}
    ;
    try std.testing.expectError(
        error.InvalidMarketMigrationState,
        MigrationState.decode(alloc, corrupt_failure),
    );

    var promoted = MigrationState.init(alloc);
    defer promoted.deinit();
    promoted.phase = .promoted;
    promoted.checkpoint_ref = try alloc.dupe(u8, "refs/checkpoints/pre-native-promotion");
    try std.testing.expectError(
        error.InvalidMarketMigrationPhase,
        promoted.markFailure("post_promotion_failure", "cannot fail promoted migration"),
    );
    try std.testing.expectError(error.InvalidMarketMigrationPhase, promoted.resumeFailure());
}
