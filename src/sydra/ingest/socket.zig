const std = @import("std");
const builtin = @import("builtin");
const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("unistd.h");
}) else struct {};
const cfg = @import("../config.zig");
const Engine = @import("../engine.zig").Engine;
const types = @import("../types.zig");
const metric_catalog_mod = @import("../storage/metric_catalog.zig");
const service = @import("service.zig");

const log = std.log.scoped(.local_ingest);

pub const protocol_version: u16 = 1;
pub const default_max_frame_bytes: usize = 8 * 1024 * 1024;
const frame_magic = "SYLI";
const frame_header_len = 16;
const capability_force_flush_drain: u32 = 1;
const flush_drain_force_flush_flag: u32 = 1;

pub const MessageKind = enum(u16) {
    hello = 1,
    hello_ack = 2,
    declare_batch = 3,
    declare_ack = 4,
    append_batch = 5,
    append_ack = 6,
    flush_drain = 7,
    flush_drain_ack = 8,
    error_message = 9,
};

const ErrorCode = enum(u16) {
    protocol_error = 1,
    unsupported_version = 2,
    frame_too_large = 3,
    decl_id_conflict = 4,
    metric_descriptor_conflict = 5,
    unknown_decl = 6,
    memory_limit_exceeded = 7,
    timeout = 8,
    invalid_decl = 9,
    handshake_required = 10,
};

const DeclareStatus = enum(u16) {
    ok = 0,
    rejected = 1,
};

pub const DeclKind = enum(u8) {
    series = 1,
    metric = 2,
};

pub const ClientDeclareInput = struct {
    decl_kind: DeclKind,
    name: []const u8,
    tags_json: []const u8,
    descriptor: ?metric_catalog_mod.DescriptorInput = null,
};

pub const ClientDeclaration = struct {
    client_decl_id: u32,
    series_id: types.SeriesId,
};

pub const AppendEntry = struct {
    client_decl_id: u32,
    ts: i64,
    value: f64,
};

pub const FlushDrainAck = struct {
    flushed: bool,
    queue_depth: usize,
    memtable_bytes: usize,
};

const ClientCacheEntry = struct {
    client_decl_id: u32,
    series_id: types.SeriesId,
};

const PendingDeclare = struct {
    result_index: usize,
    client_decl_id: u32,
    input: ClientDeclareInput,
    canonical_tags: []u8,
    signature: []u8,

    fn deinit(self: *PendingDeclare, alloc: std.mem.Allocator) void {
        alloc.free(self.canonical_tags);
        alloc.free(self.signature);
        self.* = undefined;
    }
};

const PendingAlias = struct {
    result_index: usize,
    pending_index: usize,
};

pub const BatchOptions = struct {
    max_lines_per_flush: usize = 256,
    max_points_per_flush: usize = 2048,
    max_points_per_frame: usize = 1024,
    connect_attempts: usize = 2,
    connect_retry_delay_ms: u64 = 20,
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    stream: std.net.Stream,
    max_frame_bytes: usize = default_max_frame_bytes,
    cache: std.StringHashMap(ClientCacheEntry),
    next_client_decl_id: u32 = 1,

    pub fn connect(alloc: std.mem.Allocator, path: []const u8) !Client {
        var stream = try std.net.connectUnixSocket(path);
        errdefer stream.close();

        var client = Client{
            .alloc = alloc,
            .stream = stream,
            .cache = std.StringHashMap(ClientCacheEntry).init(alloc),
        };
        errdefer client.deinit();
        try client.hello();
        return client;
    }

    pub fn connectWithRetry(alloc: std.mem.Allocator, path: []const u8, attempts: usize, retry_delay_ms: u64) !Client {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return Client.connect(alloc, path) catch |err| switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.EndOfStream,
                => {
                    if (attempt + 1 >= attempts) return err;
                    std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };
        }
    }

    pub fn deinit(self: *Client) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.cache.deinit();
        self.stream.close();
        self.* = undefined;
    }

    pub fn declareCachedBatch(self: *Client, inputs: []const ClientDeclareInput) ![]ClientDeclaration {
        var results = try self.alloc.alloc(ClientDeclaration, inputs.len);
        errdefer self.alloc.free(results);

        var pending = std.array_list.Managed(PendingDeclare).init(self.alloc);
        var pending_aliases = std.array_list.Managed(PendingAlias).init(self.alloc);
        var pending_by_signature = std.StringHashMap(usize).init(self.alloc);
        defer {
            for (pending.items) |*item| item.deinit(self.alloc);
            pending.deinit();
            pending_aliases.deinit();
            pending_by_signature.deinit();
        }

        for (inputs, 0..) |input, idx| {
            const canonical_tags = try service.canonicalizeTagsJson(self.alloc, input.tags_json);
            errdefer self.alloc.free(canonical_tags);
            const signature = try buildDeclarationSignature(self.alloc, input.decl_kind, input.name, canonical_tags, input.descriptor);
            errdefer self.alloc.free(signature);

            if (self.cache.get(signature)) |entry| {
                results[idx] = .{
                    .client_decl_id = entry.client_decl_id,
                    .series_id = entry.series_id,
                };
                self.alloc.free(canonical_tags);
                self.alloc.free(signature);
                continue;
            }

            if (pending_by_signature.get(signature)) |pending_index| {
                try pending_aliases.append(.{
                    .result_index = idx,
                    .pending_index = pending_index,
                });
                self.alloc.free(canonical_tags);
                self.alloc.free(signature);
                continue;
            }

            const client_decl_id = self.next_client_decl_id;
            self.next_client_decl_id += 1;
            try pending.append(.{
                .result_index = idx,
                .client_decl_id = client_decl_id,
                .input = input,
                .canonical_tags = canonical_tags,
                .signature = signature,
            });
            try pending_by_signature.put(signature, pending.items.len - 1);
        }

        if (pending.items.len == 0) return results;

        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();
        try appendInt(&payload, u32, @intCast(pending.items.len));
        for (pending.items) |item| {
            try encodeDeclareEntry(&payload, item.client_decl_id, item.input.decl_kind, item.input.name, item.canonical_tags, item.input.descriptor);
        }

        try self.sendFrame(.declare_batch, 0, payload.items);
        const frame = try self.receiveFrame();
        defer frame.deinit(self.alloc);

        switch (frame.kind) {
            .declare_ack => {},
            .error_message => return errorFromErrorFrame(frame.payload),
            else => return error.InvalidResponse,
        }

        var offset: usize = 0;
        const ack_count = try takeInt(u32, frame.payload, &offset);
        if (ack_count != pending.items.len) return error.InvalidResponse;
        for (pending.items, 0..) |item, idx| {
            const ack_decl_id = try takeInt(u32, frame.payload, &offset);
            const ack_status = try takeEnum(DeclareStatus, u16, frame.payload, &offset);
            const ack_code = try takeEnum(ErrorCode, u16, frame.payload, &offset);
            _ = try takeInt(u32, frame.payload, &offset); // reserved
            const series_id = try takeInt(u64, frame.payload, &offset);
            if (ack_decl_id != item.client_decl_id) return error.InvalidResponse;
            if (ack_status != .ok) return errorForCode(ack_code);

            const entry = ClientCacheEntry{
                .client_decl_id = item.client_decl_id,
                .series_id = series_id,
            };
            try self.cache.put(try self.alloc.dupe(u8, item.signature), entry);
            results[item.result_index] = .{
                .client_decl_id = item.client_decl_id,
                .series_id = series_id,
            };
            for (pending_aliases.items) |alias| {
                if (alias.pending_index != idx) continue;
                results[alias.result_index] = .{
                    .client_decl_id = item.client_decl_id,
                    .series_id = series_id,
                };
            }
        }

        return results;
    }

    pub fn appendBatch(self: *Client, entries: []const AppendEntry) !Engine.AppendBatchReceipt {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();
        try appendInt(&payload, u32, @intCast(entries.len));
        for (entries) |entry| {
            try appendInt(&payload, u32, entry.client_decl_id);
            try appendInt(&payload, i64, entry.ts);
            try appendInt(&payload, u64, @bitCast(entry.value));
        }

        try self.sendFrame(.append_batch, 0, payload.items);
        const frame = try self.receiveFrame();
        defer frame.deinit(self.alloc);
        switch (frame.kind) {
            .append_ack => {},
            .error_message => return errorFromErrorFrame(frame.payload),
            else => return error.InvalidResponse,
        }

        var offset: usize = 0;
        return .{
            .accepted_points = try takeInt(u32, frame.payload, &offset),
            .queue_depth = try takeInt(u32, frame.payload, &offset),
            .pending_bytes = try takeInt(u64, frame.payload, &offset),
        };
    }

    pub fn flushAndDrain(self: *Client, timeout_ms: u32) !FlushDrainAck {
        var payload = std.array_list.Managed(u8).init(self.alloc);
        defer payload.deinit();
        try appendInt(&payload, u32, timeout_ms);
        try appendInt(&payload, u32, flush_drain_force_flush_flag);

        try self.sendFrame(.flush_drain, 0, payload.items);
        const frame = try self.receiveFrame();
        defer frame.deinit(self.alloc);
        switch (frame.kind) {
            .flush_drain_ack => {},
            .error_message => return errorFromErrorFrame(frame.payload),
            else => return error.InvalidResponse,
        }

        var offset: usize = 0;
        const flushed = (try takeInt(u8, frame.payload, &offset)) != 0;
        offset += 3;
        return .{
            .flushed = flushed,
            .queue_depth = try takeInt(u32, frame.payload, &offset),
            .memtable_bytes = try takeInt(u64, frame.payload, &offset),
        };
    }

    fn hello(self: *Client) !void {
        try self.sendFrame(.hello, 0, &.{});
        const frame = try self.receiveFrame();
        defer frame.deinit(self.alloc);
        switch (frame.kind) {
            .hello_ack => {},
            .error_message => return errorFromErrorFrame(frame.payload),
            else => return error.InvalidResponse,
        }

        var offset: usize = 0;
        const server_version = try takeInt(u16, frame.payload, &offset);
        _ = try takeInt(u16, frame.payload, &offset);
        const max_frame_bytes = try takeInt(u32, frame.payload, &offset);
        _ = try takeInt(u32, frame.payload, &offset);
        if (server_version != protocol_version) return error.ProtocolVersionMismatch;
        self.max_frame_bytes = max_frame_bytes;
    }

    fn sendFrame(self: *Client, kind: MessageKind, flags: u16, payload: []const u8) !void {
        var out_buf: [4096]u8 = undefined;
        var writer_state = self.stream.writer(&out_buf);
        try writeFrame(&writer_state.interface, kind, flags, payload);
        try writer_state.interface.flush();
    }

    fn receiveFrame(self: *Client) !Frame {
        var in_buf: [4096]u8 = undefined;
        var reader_state = self.stream.reader(&in_buf);
        const reader = std.Io.Reader.adaptToOldInterface(reader_state.interface());
        return try readFrameAlloc(self.alloc, reader, self.max_frame_bytes);
    }
};

pub const ParsedLineBatcher = struct {
    alloc: std.mem.Allocator,
    client: *Client,
    options: BatchOptions,
    lines: std.array_list.Managed(service.ParsedIngestLine),
    pending_points: usize = 0,

    pub fn init(alloc: std.mem.Allocator, client: *Client, options: BatchOptions) ParsedLineBatcher {
        return .{
            .alloc = alloc,
            .client = client,
            .options = options,
            .lines = std.array_list.Managed(service.ParsedIngestLine).init(alloc),
        };
    }

    pub fn deinit(self: *ParsedLineBatcher) void {
        for (self.lines.items) |line| line.deinit(self.alloc);
        self.lines.deinit();
        self.* = undefined;
    }

    pub fn push(self: *ParsedLineBatcher, parsed: service.ParsedIngestLine) !usize {
        self.pending_points += parsed.writes.len;
        try self.lines.append(parsed);
        if (self.lines.items.len >= self.options.max_lines_per_flush or self.pending_points >= self.options.max_points_per_flush) {
            return try self.flush();
        }
        return 0;
    }

    pub fn flush(self: *ParsedLineBatcher) !usize {
        if (self.lines.items.len == 0) return 0;
        const accepted = try appendParsedLines(self.alloc, self.client, self.lines.items, self.options.max_points_per_frame);
        for (self.lines.items) |line| line.deinit(self.alloc);
        self.lines.clearRetainingCapacity();
        self.pending_points = 0;
        return accepted;
    }
};

pub fn appendParsedLines(
    alloc: std.mem.Allocator,
    client: *Client,
    parsed_lines: []const service.ParsedIngestLine,
    max_points_per_frame: usize,
) !usize {
    var total_points: usize = 0;
    for (parsed_lines) |line| total_points += line.writes.len;
    if (total_points == 0) return 0;

    const declarations = try alloc.alloc(ClientDeclareInput, total_points);
    defer alloc.free(declarations);

    var decl_idx: usize = 0;
    for (parsed_lines) |line| {
        for (line.writes) |write| {
            declarations[decl_idx] = .{
                .decl_kind = if (write.descriptor != null) .metric else .series,
                .name = write.series,
                .tags_json = line.tags_json,
                .descriptor = service.descriptorInput(&write),
            };
            decl_idx += 1;
        }
    }

    const declared = try client.declareCachedBatch(declarations);
    defer alloc.free(declared);

    const frame_cap = @max(@as(usize, 1), max_points_per_frame);
    const append_entries = try alloc.alloc(AppendEntry, @min(frame_cap, total_points));
    defer alloc.free(append_entries);

    var accepted_total: usize = 0;
    var pending_frame: usize = 0;
    decl_idx = 0;
    for (parsed_lines) |line| {
        for (line.writes) |write| {
            append_entries[pending_frame] = .{
                .client_decl_id = declared[decl_idx].client_decl_id,
                .ts = line.ts,
                .value = write.value,
            };
            pending_frame += 1;
            decl_idx += 1;
            if (pending_frame == append_entries.len) {
                const receipt = try client.appendBatch(append_entries[0..pending_frame]);
                accepted_total += receipt.accepted_points;
                pending_frame = 0;
            }
        }
    }
    if (pending_frame != 0) {
        const receipt = try client.appendBatch(append_entries[0..pending_frame]);
        accepted_total += receipt.accepted_points;
    }
    return accepted_total;
}

const Frame = struct {
    kind: MessageKind,
    flags: u16,
    payload: []u8,

    fn deinit(self: Frame, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
    }
};

const ServerDeclaration = struct {
    signature: []u8,
    series_id: types.SeriesId,

    fn deinit(self: *ServerDeclaration, alloc: std.mem.Allocator) void {
        alloc.free(self.signature);
        self.* = undefined;
    }
};

const SessionState = struct {
    alloc: std.mem.Allocator,
    declarations: std.AutoHashMap(u32, ServerDeclaration),
    hello_complete: bool = false,

    fn init(alloc: std.mem.Allocator) SessionState {
        return .{
            .alloc = alloc,
            .declarations = std.AutoHashMap(u32, ServerDeclaration).init(alloc),
        };
    }

    fn deinit(self: *SessionState) void {
        var it = self.declarations.valueIterator();
        while (it.next()) |entry| entry.deinit(self.alloc);
        self.declarations.deinit();
    }
};

const BorrowedDeclareEntry = struct {
    client_decl_id: u32,
    decl_kind: DeclKind,
    name: []const u8,
    tags_json: []const u8,
    descriptor: ?metric_catalog_mod.DescriptorInput,
};

const PeerCredentials = struct {
    uid: ?u32 = null,
    gid: ?u32 = null,
    pid: ?u32 = null,
};

pub fn validateSocketListenPath(socket_path: []const u8) !void {
    _ = try std.net.Address.initUnix(socket_path);
    try prepareSocketPath(socket_path);
}

pub fn runUnixSocket(eng: *Engine, socket_path: []const u8, max_frame_bytes: usize) !void {
    if (!std.net.has_unix_sockets) return error.UnixSocketsUnsupported;
    try validateSocketListenPath(socket_path);

    var address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    defer {
        server.deinit();
        cleanupSocketPath(socket_path);
    }

    bestEffortChmod0600(socket_path);
    log.info("local ingest socket listening on {s}", .{socket_path});

    while (true) {
        const connection = server.accept() catch |err| switch (err) {
            error.ConnectionResetByPeer, error.ConnectionAborted => continue,
            else => return err,
        };
        _ = eng.metrics.local_ingest_connections_total.fetchAdd(1, .monotonic);
        _ = eng.metrics.local_ingest_connections_current.fetchAdd(1, .monotonic);
        const worker = std.Thread.spawn(.{}, connectionWorker, .{ eng, connection, max_frame_bytes }) catch |spawn_err| {
            _ = eng.metrics.local_ingest_connections_current.fetchSub(1, .monotonic);
            log.err("local ingest spawn failed: {s}", .{@errorName(spawn_err)});
            connection.stream.close();
            continue;
        };
        worker.detach();
    }
}

fn connectionWorker(eng: *Engine, connection: std.net.Server.Connection, max_frame_bytes: usize) void {
    defer {
        _ = eng.metrics.local_ingest_connections_current.fetchSub(1, .monotonic);
        connection.stream.close();
    }

    const peer = loadPeerCredentials(connection.stream);
    log.info("local ingest peer connected uid={any} gid={any} pid={any}", .{ peer.uid, peer.gid, peer.pid });

    var session = SessionState.init(eng.alloc);
    defer session.deinit();

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    var reader_state = connection.stream.reader(&in_buf);
    var writer_state = connection.stream.writer(&out_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_state.interface());
    const writer = &writer_state.interface;

    while (true) {
        const frame = readFrameAlloc(eng.alloc, reader, max_frame_bytes) catch |err| switch (err) {
            error.EndOfStream => return,
            error.FrameTooLarge => {
                _ = eng.metrics.local_ingest_frame_too_large_total.fetchAdd(1, .monotonic);
                sendErrorFrame(writer, .frame_too_large, "frame too large") catch {};
                writer.flush() catch {};
                return;
            },
            error.UnsupportedVersion => {
                _ = eng.metrics.local_ingest_protocol_error_total.fetchAdd(1, .monotonic);
                sendErrorFrame(writer, .unsupported_version, "unsupported protocol version") catch {};
                writer.flush() catch {};
                return;
            },
            error.InvalidFrame => {
                _ = eng.metrics.local_ingest_protocol_error_total.fetchAdd(1, .monotonic);
                sendErrorFrame(writer, .protocol_error, "invalid frame") catch {};
                writer.flush() catch {};
                return;
            },
            else => {
                log.warn("local ingest read failed: {s}", .{@errorName(err)});
                return;
            },
        };
        defer frame.deinit(eng.alloc);

        _ = eng.metrics.local_ingest_frames_total.fetchAdd(1, .monotonic);
        _ = eng.metrics.local_ingest_frame_bytes_total.fetchAdd(frame.payload.len + frame_header_len, .monotonic);

        if (!session.hello_complete and frame.kind != .hello) {
            _ = eng.metrics.local_ingest_protocol_error_total.fetchAdd(1, .monotonic);
            _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
            sendErrorFrame(writer, .handshake_required, "hello required") catch {};
            writer.flush() catch {};
            return;
        }

        switch (frame.kind) {
            .hello => {
                handleHello(writer, max_frame_bytes) catch |err| {
                    log.warn("local ingest hello failed: {s}", .{@errorName(err)});
                    return;
                };
                session.hello_complete = true;
            },
            .declare_batch => handleDeclareBatch(eng, &session, frame.payload, writer) catch |err| {
                log.warn("local ingest declare failed: {s}", .{@errorName(err)});
                return;
            },
            .append_batch => handleAppendBatch(eng, &session, frame.payload, writer) catch |err| {
                log.warn("local ingest append failed: {s}", .{@errorName(err)});
                return;
            },
            .flush_drain => handleFlushDrain(eng, frame.payload, writer) catch |err| {
                log.warn("local ingest flush failed: {s}", .{@errorName(err)});
                return;
            },
            .hello_ack, .declare_ack, .append_ack, .flush_drain_ack, .error_message => {
                _ = eng.metrics.local_ingest_protocol_error_total.fetchAdd(1, .monotonic);
                sendErrorFrame(writer, .protocol_error, "unexpected frame kind") catch {};
                writer.flush() catch {};
                return;
            },
        }
        writer.flush() catch |err| {
            log.warn("local ingest writer flush failed: {s}", .{@errorName(err)});
            return;
        };
    }
}

fn handleHello(writer: *std.Io.Writer, max_frame_bytes: usize) !void {
    var payload = std.array_list.Managed(u8).init(std.heap.c_allocator);
    defer payload.deinit();
    try appendInt(&payload, u16, protocol_version);
    try appendInt(&payload, u16, 0);
    try appendInt(&payload, u32, @intCast(max_frame_bytes));
    try appendInt(&payload, u32, capability_force_flush_drain);
    try writeFrame(writer, .hello_ack, 0, payload.items);
}

fn handleDeclareBatch(eng: *Engine, session: *SessionState, payload: []const u8, writer: *std.Io.Writer) !void {
    const start_ns = std.time.nanoTimestamp();
    var offset: usize = 0;
    const count = try takeInt(u32, payload, &offset);
    var response = std.array_list.Managed(u8).init(eng.alloc);
    defer response.deinit();
    try appendInt(&response, u32, count);

    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const entry = try parseDeclareEntry(payload, &offset);
        const canonical_tags = service.canonicalizeTagsJson(eng.alloc, entry.tags_json) catch {
            _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
            try appendDeclareAckEntry(&response, entry.client_decl_id, .rejected, .invalid_decl, 0);
            continue;
        };
        defer eng.alloc.free(canonical_tags);

        const signature = try buildDeclarationSignature(eng.alloc, entry.decl_kind, entry.name, canonical_tags, entry.descriptor);
        var stored_signature = false;
        defer if (!stored_signature) eng.alloc.free(signature);

        if (session.declarations.get(entry.client_decl_id)) |existing| {
            if (std.mem.eql(u8, existing.signature, signature)) {
                try appendDeclareAckEntry(&response, entry.client_decl_id, .ok, .protocol_error, existing.series_id);
            } else {
                _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
                try appendDeclareAckEntry(&response, entry.client_decl_id, .rejected, .decl_id_conflict, 0);
            }
            continue;
        }

        const series_id = eng.declareExactSeriesCanonical(entry.name, canonical_tags, entry.descriptor) catch |err| switch (err) {
            error.MetricDescriptorConflict => blk: {
                _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
                try appendDeclareAckEntry(&response, entry.client_decl_id, .rejected, .metric_descriptor_conflict, 0);
                break :blk null;
            },
            else => return err,
        };
        if (series_id == null) continue;

        try session.declarations.put(entry.client_decl_id, .{
            .signature = signature,
            .series_id = series_id.?,
        });
        stored_signature = true;
        _ = eng.metrics.local_ingest_declare_total.fetchAdd(1, .monotonic);
        try appendDeclareAckEntry(&response, entry.client_decl_id, .ok, .protocol_error, series_id.?);
    }

    const elapsed_ns = std.time.nanoTimestamp() - start_ns;
    _ = eng.metrics.local_ingest_declare_batches_total.fetchAdd(1, .monotonic);
    _ = eng.metrics.local_ingest_declare_ns_total.fetchAdd(@intCast(elapsed_ns), .monotonic);
    try writeFrame(writer, .declare_ack, 0, response.items);
}

fn handleAppendBatch(eng: *Engine, session: *SessionState, payload: []const u8, writer: *std.Io.Writer) !void {
    const start_ns = std.time.nanoTimestamp();
    var offset: usize = 0;
    const count = try takeInt(u32, payload, &offset);
    var points = try eng.alloc.alloc(Engine.ResolvedIngestPoint, count);
    defer eng.alloc.free(points);

    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const client_decl_id = try takeInt(u32, payload, &offset);
        const ts = try takeInt(i64, payload, &offset);
        const value = @as(f64, @bitCast(try takeInt(u64, payload, &offset)));

        const declaration = session.declarations.get(client_decl_id) orelse {
            _ = eng.metrics.local_ingest_unknown_decl_total.fetchAdd(1, .monotonic);
            _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
            try sendErrorFrame(writer, .unknown_decl, "unknown declaration");
            return;
        };
        points[idx] = .{
            .series_id = declaration.series_id,
            .ts = ts,
            .value = value,
        };
    }

    const receipt = eng.appendResolvedBatch(points) catch |err| switch (err) {
        error.MemoryLimitExceeded => {
            _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
            try sendErrorFrame(writer, .memory_limit_exceeded, "ingest backpressure: memory limit exceeded");
            return;
        },
        else => return err,
    };

    _ = eng.metrics.local_ingest_append_points_total.fetchAdd(receipt.accepted_points, .monotonic);
    _ = eng.metrics.local_ingest_append_batches_total.fetchAdd(1, .monotonic);
    _ = eng.metrics.local_ingest_append_ns_total.fetchAdd(@intCast(std.time.nanoTimestamp() - start_ns), .monotonic);
    var current_max = eng.metrics.local_ingest_append_batch_points_max.load(.monotonic);
    while (receipt.accepted_points > current_max) {
        if (eng.metrics.local_ingest_append_batch_points_max.cmpxchgWeak(current_max, receipt.accepted_points, .monotonic, .monotonic)) |prev|
            current_max = prev
        else
            break;
    }
    var response = std.array_list.Managed(u8).init(eng.alloc);
    defer response.deinit();
    try appendInt(&response, u32, @intCast(receipt.accepted_points));
    try appendInt(&response, u32, @intCast(receipt.queue_depth));
    try appendInt(&response, u64, @intCast(receipt.pending_bytes));
    try writeFrame(writer, .append_ack, 0, response.items);
}

fn handleFlushDrain(eng: *Engine, payload: []const u8, writer: *std.Io.Writer) !void {
    var offset: usize = 0;
    const timeout_ms = try takeInt(u32, payload, &offset);
    const flags = try takeInt(u32, payload, &offset);
    _ = flags;

    const flushed = eng.flushAndDrain(timeout_ms) catch |err| switch (err) {
        error.Timeout => {
            _ = eng.metrics.local_ingest_rejected_total.fetchAdd(1, .monotonic);
            try sendErrorFrame(writer, .timeout, "flush and drain timed out");
            return;
        },
        else => return err,
    };

    var response = std.array_list.Managed(u8).init(eng.alloc);
    defer response.deinit();
    try response.append(if (flushed) 1 else 0);
    try response.appendNTimes(0, 3);
    try appendInt(&response, u32, @intCast(eng.queue.len()));
    try appendInt(&response, u64, @intCast(eng.mem.bytes.load(.monotonic)));
    try writeFrame(writer, .flush_drain_ack, 0, response.items);
}

fn prepareSocketPath(socket_path: []const u8) !void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(socket_path)) |dir_name| {
        if (dir_name.len != 0) try cwd.makePath(dir_name);
    }

    const stat = cwd.statFile(socket_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return error.PathAlreadyExists;

    const probe = std.net.connectUnixSocket(socket_path) catch |err| switch (err) {
        error.ConnectionRefused => {
            try cwd.deleteFile(socket_path);
            return;
        },
        error.FileNotFound => return,
        else => return err,
    };
    probe.close();
    return error.AlreadyListening;
}

fn cleanupSocketPath(socket_path: []const u8) void {
    std.fs.cwd().deleteFile(socket_path) catch {};
}

fn bestEffortChmod0600(socket_path: []const u8) void {
    std.posix.fchmodat(std.fs.cwd().fd, socket_path, 0o600, 0) catch {};
}

fn loadPeerCredentials(stream: std.net.Stream) PeerCredentials {
    switch (builtin.os.tag) {
        .linux => {
            if (@hasDecl(std.posix.SO, "PEERCRED")) {
                const LinuxUcred = extern struct {
                    pid: i32,
                    uid: u32,
                    gid: u32,
                };
                var cred = std.mem.zeroes(LinuxUcred);
                std.posix.getsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&cred)) catch return .{};
                return .{
                    .uid = cred.uid,
                    .gid = cred.gid,
                    .pid = @intCast(cred.pid),
                };
            }
        },
        .macos => {
            var uid: c.uid_t = 0;
            var gid: c.gid_t = 0;
            if (c.getpeereid(stream.handle, &uid, &gid) == 0) {
                return .{
                    .uid = uid,
                    .gid = gid,
                };
            }
        },
        else => {},
    }
    return .{};
}

fn readFrameAlloc(alloc: std.mem.Allocator, reader: anytype, max_frame_bytes: usize) !Frame {
    var header: [frame_header_len]u8 = undefined;
    try reader.readNoEof(header[0..]);
    if (!std.mem.eql(u8, header[0..4], frame_magic)) return error.InvalidFrame;

    const version = std.mem.readInt(u16, header[4..6], .little);
    const kind_raw = std.mem.readInt(u16, header[6..8], .little);
    const flags = std.mem.readInt(u16, header[8..10], .little);
    const payload_len = std.mem.readInt(u32, header[12..16], .little);

    if (version != protocol_version) return error.UnsupportedVersion;
    if (payload_len > max_frame_bytes) return error.FrameTooLarge;

    const kind = std.meta.intToEnum(MessageKind, kind_raw) catch return error.InvalidFrame;
    const payload = try alloc.alloc(u8, payload_len);
    errdefer alloc.free(payload);
    try reader.readNoEof(payload);
    return .{
        .kind = kind,
        .flags = flags,
        .payload = payload,
    };
}

fn writeFrame(writer: *std.Io.Writer, kind: MessageKind, flags: u16, payload: []const u8) !void {
    var header: [frame_header_len]u8 = undefined;
    @memcpy(header[0..4], frame_magic);
    std.mem.writeInt(u16, header[4..6], protocol_version, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(kind), .little);
    std.mem.writeInt(u16, header[8..10], flags, .little);
    std.mem.writeInt(u16, header[10..12], 0, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(payload.len), .little);
    try writer.writeAll(header[0..]);
    try writer.writeAll(payload);
}

fn sendErrorFrame(writer: *std.Io.Writer, code: ErrorCode, message: []const u8) !void {
    var payload = std.array_list.Managed(u8).init(std.heap.c_allocator);
    defer payload.deinit();
    try appendInt(&payload, u16, @intFromEnum(code));
    try appendInt(&payload, u16, 0);
    try appendInt(&payload, u32, @intCast(message.len));
    try payload.appendSlice(message);
    try writeFrame(writer, .error_message, 0, payload.items);
}

fn buildDeclarationSignature(
    alloc: std.mem.Allocator,
    decl_kind: DeclKind,
    name: []const u8,
    canonical_tags: []const u8,
    descriptor: ?metric_catalog_mod.DescriptorInput,
) ![]u8 {
    var payload = std.array_list.Managed(u8).init(alloc);
    errdefer payload.deinit();
    try payload.append(@intFromEnum(decl_kind));
    try payload.appendNTimes(0, 3);
    try appendBytesWithLen(&payload, name);
    try appendBytesWithLen(&payload, canonical_tags);
    if (descriptor) |desc| {
        try payload.append(1);
        try payload.append(if (desc.kind) |kind| @as(u8, @intFromEnum(kind)) + 1 else 0);
        try payload.appendNTimes(0, 2);
        try appendOptionalBytes(&payload, desc.unit);
        try appendOptionalBytes(&payload, desc.description);
        try appendOptionalBytes(&payload, desc.source_metric);
        try appendOptionalBytes(&payload, desc.source_field);
    } else {
        try payload.appendNTimes(0, 4);
        try appendOptionalBytes(&payload, null);
        try appendOptionalBytes(&payload, null);
        try appendOptionalBytes(&payload, null);
        try appendOptionalBytes(&payload, null);
    }
    return try payload.toOwnedSlice();
}

fn encodeDeclareEntry(
    payload: *std.array_list.Managed(u8),
    client_decl_id: u32,
    decl_kind: DeclKind,
    name: []const u8,
    canonical_tags: []const u8,
    descriptor: ?metric_catalog_mod.DescriptorInput,
) !void {
    try appendInt(payload, u32, client_decl_id);
    try payload.append(@intFromEnum(decl_kind));
    try payload.append(if (descriptor != null) 1 else 0);
    try payload.appendNTimes(0, 2);
    try appendBytesWithLen(payload, name);
    try appendBytesWithLen(payload, canonical_tags);
    if (descriptor) |desc| {
        try payload.append(if (desc.kind) |kind| @as(u8, @intFromEnum(kind)) + 1 else 0);
        try payload.appendNTimes(0, 3);
        try appendOptionalBytes(payload, desc.unit);
        try appendOptionalBytes(payload, desc.description);
        try appendOptionalBytes(payload, desc.source_metric);
        try appendOptionalBytes(payload, desc.source_field);
    }
}

fn parseDeclareEntry(payload: []const u8, offset: *usize) !BorrowedDeclareEntry {
    const client_decl_id = try takeInt(u32, payload, offset);
    const decl_kind = try takeEnum(DeclKind, u8, payload, offset);
    const descriptor_present = (try takeInt(u8, payload, offset)) != 0;
    offset.* += 2;
    const name = try takeBytesWithLen(payload, offset);
    const tags_json = try takeBytesWithLen(payload, offset);

    var descriptor: ?metric_catalog_mod.DescriptorInput = null;
    if (descriptor_present) {
        const kind_raw = try takeInt(u8, payload, offset);
        offset.* += 3;
        const unit = try takeOptionalBytes(payload, offset);
        const description = try takeOptionalBytes(payload, offset);
        const source_metric = try takeOptionalBytes(payload, offset);
        const source_field = try takeOptionalBytes(payload, offset);
        descriptor = .{
            .metric = name,
            .kind = switch (kind_raw) {
                0 => null,
                1 => .gauge,
                2 => .counter,
                else => return error.InvalidFrame,
            },
            .unit = unit,
            .description = description,
            .source_metric = source_metric,
            .source_field = source_field,
        };
    }

    return .{
        .client_decl_id = client_decl_id,
        .decl_kind = decl_kind,
        .name = name,
        .tags_json = tags_json,
        .descriptor = descriptor,
    };
}

fn appendDeclareAckEntry(
    payload: *std.array_list.Managed(u8),
    client_decl_id: u32,
    status: DeclareStatus,
    code: ErrorCode,
    series_id: types.SeriesId,
) !void {
    try appendInt(payload, u32, client_decl_id);
    try appendInt(payload, u16, @intFromEnum(status));
    try appendInt(payload, u16, @intFromEnum(code));
    try appendInt(payload, u32, 0);
    try appendInt(payload, u64, series_id);
}

fn errorFromErrorFrame(payload: []const u8) anyerror {
    var offset: usize = 0;
    const code = takeEnum(ErrorCode, u16, payload, &offset) catch return error.InvalidResponse;
    _ = takeInt(u16, payload, &offset) catch return error.InvalidResponse;
    const message_len = takeInt(u32, payload, &offset) catch return error.InvalidResponse;
    if (offset + message_len > payload.len) return error.InvalidResponse;
    const message = payload[offset .. offset + message_len];
    log.warn("local ingest server rejected request: code={s} message={s}", .{ @tagName(code), message });
    return errorForCode(code);
}

fn errorForCode(code: ErrorCode) anyerror {
    return switch (code) {
        .unsupported_version => error.ProtocolVersionMismatch,
        .decl_id_conflict => error.DeclarationConflict,
        .metric_descriptor_conflict => error.MetricDescriptorConflict,
        .unknown_decl => error.UnknownDeclaration,
        .memory_limit_exceeded => error.MemoryLimitExceeded,
        .timeout => error.Timeout,
        .frame_too_large => error.FrameTooLarge,
        .invalid_decl, .handshake_required, .protocol_error => error.RemoteRejected,
    };
}

fn appendInt(list: *std.array_list.Managed(u8), comptime T: type, value: T) !void {
    var raw: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &raw, value, .little);
    try list.appendSlice(raw[0..]);
}

fn appendBytesWithLen(list: *std.array_list.Managed(u8), bytes: []const u8) !void {
    try appendInt(list, u32, @intCast(bytes.len));
    try list.appendSlice(bytes);
}

fn appendOptionalBytes(list: *std.array_list.Managed(u8), maybe_bytes: ?[]const u8) !void {
    if (maybe_bytes) |bytes| {
        try appendBytesWithLen(list, bytes);
    } else {
        try appendInt(list, u32, 0);
    }
}

fn takeInt(comptime T: type, bytes: []const u8, offset: *usize) !T {
    if (offset.* + @sizeOf(T) > bytes.len) return error.InvalidFrame;
    var raw: [@sizeOf(T)]u8 = undefined;
    @memcpy(raw[0..], bytes[offset.* .. offset.* + @sizeOf(T)]);
    const value = std.mem.readInt(T, &raw, .little);
    offset.* += @sizeOf(T);
    return value;
}

fn takeEnum(comptime E: type, comptime T: type, bytes: []const u8, offset: *usize) !E {
    return std.meta.intToEnum(E, try takeInt(T, bytes, offset)) catch error.InvalidFrame;
}

fn takeBytesWithLen(bytes: []const u8, offset: *usize) ![]const u8 {
    const len = try takeInt(u32, bytes, offset);
    if (offset.* + len > bytes.len) return error.InvalidFrame;
    const out = bytes[offset.* .. offset.* + len];
    offset.* += len;
    return out;
}

fn takeOptionalBytes(bytes: []const u8, offset: *usize) !?[]const u8 {
    const value = try takeBytesWithLen(bytes, offset);
    if (value.len == 0) return null;
    return value;
}

fn testConfig(alloc: std.mem.Allocator, data_path: []const u8) !cfg.Config {
    return .{
        .data_dir = try alloc.dupe(u8, data_path),
        .http_port = 0,
        .fsync = .none,
        .flush_interval_ms = 5,
        .memtable_max_bytes = 512,
        .retention_days = 0,
        .auth_token = try alloc.dupe(u8, ""),
        .enable_influx = false,
        .enable_prom = false,
        .mem_limit_bytes = 1024 * 1024,
        .cas_mode = .off,
        .retention_ns = std.StringHashMap(u32).init(alloc),
    };
}

fn testOneShotServer(eng: *Engine, socket_path: []const u8, max_frame_bytes: usize) !void {
    try validateSocketListenPath(socket_path);
    var address = try std.net.Address.initUnix(socket_path);
    var server = try address.listen(.{});
    defer {
        server.deinit();
        cleanupSocketPath(socket_path);
    }

    bestEffortChmod0600(socket_path);
    const connection = try server.accept();
    connectionWorker(eng, connection, max_frame_bytes);
}

fn connectRawWithRetry(path: []const u8, attempts: usize, retry_delay_ms: u64) !std.net.Stream {
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        return std.net.connectUnixSocket(path) catch |err| switch (err) {
            error.FileNotFound,
            error.ConnectionRefused,
            => {
                if (attempt + 1 >= attempts) return err;
                std.Thread.sleep(retry_delay_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
    }
    unreachable;
}

fn writeFrameWithVersion(stream: std.net.Stream, version: u16, kind: MessageKind, flags: u16, payload: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var writer_state = stream.writer(&out_buf);

    var header: [frame_header_len]u8 = undefined;
    @memcpy(header[0..4], frame_magic);
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(kind), .little);
    std.mem.writeInt(u16, header[8..10], flags, .little);
    std.mem.writeInt(u16, header[10..12], 0, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(payload.len), .little);
    try writer_state.interface.writeAll(header[0..]);
    try writer_state.interface.writeAll(payload);
    try writer_state.interface.flush();
}

fn readFrameFromStream(alloc: std.mem.Allocator, stream: std.net.Stream, max_frame_bytes: usize) !Frame {
    var in_buf: [4096]u8 = undefined;
    var reader_state = stream.reader(&in_buf);
    const reader = std.Io.Reader.adaptToOldInterface(reader_state.interface());
    return try readFrameAlloc(alloc, reader, max_frame_bytes);
}

fn readDeclareAckResult(payload: []const u8) !struct {
    client_decl_id: u32,
    status: DeclareStatus,
    code: ErrorCode,
    series_id: types.SeriesId,
} {
    var offset: usize = 0;
    const count = try takeInt(u32, payload, &offset);
    if (count != 1) return error.InvalidFrame;
    const result = .{
        .client_decl_id = try takeInt(u32, payload, &offset),
        .status = try takeEnum(DeclareStatus, u16, payload, &offset),
        .code = try takeEnum(ErrorCode, u16, payload, &offset),
        .series_id = blk: {
            _ = try takeInt(u32, payload, &offset);
            break :blk try takeInt(u64, payload, &offset);
        },
    };
    if (offset != payload.len) return error.InvalidFrame;
    return result;
}

fn readErrorCode(payload: []const u8) !ErrorCode {
    var offset: usize = 0;
    const code = try takeEnum(ErrorCode, u16, payload, &offset);
    _ = try takeInt(u16, payload, &offset);
    const msg_len = try takeInt(u32, payload, &offset);
    if (offset + msg_len > payload.len) return error.InvalidFrame;
    return code;
}

test "socket frame round trip preserves kind flags and payload" {
    const alloc = std.testing.allocator;
    var bytes = std.array_list.Managed(u8).init(alloc);
    defer bytes.deinit();

    var writer = bytes.writer();
    var tmp: [128]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    try writeFrame(&adapter.new_interface, .append_batch, 7, "hello");
    try adapter.new_interface.flush();
    if (adapter.err) |err| return err;

    var fixed = std.io.fixedBufferStream(bytes.items);
    const frame = try readFrameAlloc(alloc, fixed.reader(), default_max_frame_bytes);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(MessageKind.append_batch, frame.kind);
    try std.testing.expectEqual(@as(u16, 7), frame.flags);
    try std.testing.expectEqualStrings("hello", frame.payload);
}

test "socket declaration signatures distinguish descriptor metadata" {
    const alloc = std.testing.allocator;
    const canonical_tags = try service.canonicalizeTagsJson(alloc, "{\"b\":\"2\",\"a\":\"1\"}");
    defer alloc.free(canonical_tags);

    const base = try buildDeclarationSignature(alloc, .metric, "svc.req", canonical_tags, .{
        .metric = "svc.req",
        .kind = .counter,
        .unit = "requests",
    });
    defer alloc.free(base);
    const same = try buildDeclarationSignature(alloc, .metric, "svc.req", canonical_tags, .{
        .metric = "svc.req",
        .kind = .counter,
        .unit = "requests",
    });
    defer alloc.free(same);
    const different = try buildDeclarationSignature(alloc, .metric, "svc.req", canonical_tags, .{
        .metric = "svc.req",
        .kind = .gauge,
        .unit = "requests",
    });
    defer alloc.free(different);

    try std.testing.expect(std.mem.eql(u8, base, same));
    try std.testing.expect(!std.mem.eql(u8, base, different));
}

test "socket error codes map to stable client-visible errors" {
    try std.testing.expectError(error.ProtocolVersionMismatch, errorForCode(.unsupported_version));
    try std.testing.expectError(error.DeclarationConflict, errorForCode(.decl_id_conflict));
    try std.testing.expectError(error.UnknownDeclaration, errorForCode(.unknown_decl));
    try std.testing.expectError(error.MemoryLimitExceeded, errorForCode(.memory_limit_exceeded));
    try std.testing.expectError(error.Timeout, errorForCode(.timeout));
    try std.testing.expectError(error.RemoteRejected, errorForCode(.protocol_error));
}

test "socket listen path validation cleans stale sockets and rejects busy paths" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/validate.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    try std.fs.cwd().writeFile(.{ .sub_path = socket_path, .data = "x" });
    try std.testing.expectError(error.PathAlreadyExists, validateSocketListenPath(socket_path));
    try std.fs.cwd().deleteFile(socket_path);

    var stale_address = try std.net.Address.initUnix(socket_path);
    var stale_server = try stale_address.listen(.{});
    stale_server.deinit();
    try validateSocketListenPath(socket_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().statFile(socket_path));

    var live_address = try std.net.Address.initUnix(socket_path);
    var live_server = try live_address.listen(.{});
    defer {
        live_server.deinit();
        cleanupSocketPath(socket_path);
    }
    try std.testing.expectError(error.AlreadyListening, validateSocketListenPath(socket_path));
}

test "socket client round trips declare append and flush" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/client-roundtrip", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/client-roundtrip.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var client = try Client.connectWithRetry(alloc, socket_path, 20, 10);

    const inputs = [_]ClientDeclareInput{
        .{
            .decl_kind = .metric,
            .name = "svc.req",
            .tags_json = "{\"host\":\"web-1\"}",
            .descriptor = .{
                .metric = "svc.req",
                .kind = .counter,
                .unit = "requests",
            },
        },
        .{
            .decl_kind = .metric,
            .name = "svc.req",
            .tags_json = "{\"host\":\"web-1\"}",
            .descriptor = .{
                .metric = "svc.req",
                .kind = .counter,
                .unit = "requests",
            },
        },
    };
    const declared = try client.declareCachedBatch(&inputs);
    defer alloc.free(declared);
    try std.testing.expectEqual(@as(usize, 2), declared.len);
    try std.testing.expectEqual(declared[0].client_decl_id, declared[1].client_decl_id);
    try std.testing.expectEqual(declared[0].series_id, declared[1].series_id);

    const receipt = try client.appendBatch(&.{
        .{ .client_decl_id = declared[0].client_decl_id, .ts = 10, .value = 1.25 },
        .{ .client_decl_id = declared[1].client_decl_id, .ts = 20, .value = 2.5 },
    });
    try std.testing.expectEqual(@as(usize, 2), receipt.accepted_points);
    try std.testing.expect(try client.flushAndDrain(1_000)).flushed;
    client.deinit();
    server_thread.join();

    var points = std.array_list.Managed(types.Point).init(alloc);
    defer points.deinit();
    try eng.queryRange(declared[0].series_id, 0, 100, &points);
    try std.testing.expectEqual(@as(usize, 2), points.items.len);
    try std.testing.expectEqual(@as(i64, 10), points.items[0].ts);
    try std.testing.expectEqual(@as(i64, 20), points.items[1].ts);
    const descriptor = eng.metricDescriptor("svc.req").?;
    try std.testing.expectEqual(metric_catalog_mod.MetricKind.counter, descriptor.kind.?);
}

test "socket protocol preserves declaration idempotency and reports conflicts" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/decl-conflict", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/decl-conflict.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var stream = try connectRawWithRetry(socket_path, 20, 10);

    try writeFrameWithVersion(stream, protocol_version, .hello, 0, &.{});
    var hello = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer hello.deinit(alloc);
    try std.testing.expectEqual(MessageKind.hello_ack, hello.kind);

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try appendInt(&payload, u32, 1);
    try encodeDeclareEntry(&payload, 1, .series, "svc.req", "{}", null);
    try writeFrameWithVersion(stream, protocol_version, .declare_batch, 0, payload.items);
    var first = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer first.deinit(alloc);
    const first_ack = try readDeclareAckResult(first.payload);
    try std.testing.expectEqual(DeclareStatus.ok, first_ack.status);

    try writeFrameWithVersion(stream, protocol_version, .declare_batch, 0, payload.items);
    var second = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer second.deinit(alloc);
    const second_ack = try readDeclareAckResult(second.payload);
    try std.testing.expectEqual(DeclareStatus.ok, second_ack.status);
    try std.testing.expectEqual(first_ack.series_id, second_ack.series_id);

    payload.clearRetainingCapacity();
    try appendInt(&payload, u32, 1);
    try encodeDeclareEntry(&payload, 1, .series, "svc.other", "{}", null);
    try writeFrameWithVersion(stream, protocol_version, .declare_batch, 0, payload.items);
    var conflict = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer conflict.deinit(alloc);
    const conflict_ack = try readDeclareAckResult(conflict.payload);
    try std.testing.expectEqual(DeclareStatus.rejected, conflict_ack.status);
    try std.testing.expectEqual(ErrorCode.decl_id_conflict, conflict_ack.code);

    stream.close();
    server_thread.join();
}

test "socket server rejects appends for unknown declarations" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/unknown-decl", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/unknown-decl.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var stream = try connectRawWithRetry(socket_path, 20, 10);

    try writeFrameWithVersion(stream, protocol_version, .hello, 0, &.{});
    var hello = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer hello.deinit(alloc);

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try appendInt(&payload, u32, 1);
    try appendInt(&payload, u32, 999);
    try appendInt(&payload, i64, 10);
    try appendInt(&payload, u64, @bitCast(@as(f64, 1.5)));
    try writeFrameWithVersion(stream, protocol_version, .append_batch, 0, payload.items);

    var frame = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer frame.deinit(alloc);
    try std.testing.expectEqual(MessageKind.error_message, frame.kind);
    try std.testing.expectEqual(ErrorCode.unknown_decl, try readErrorCode(frame.payload));

    stream.close();
    server_thread.join();
}

test "socket server rejects unsupported protocol versions" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/bad-version", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/bad-version.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var stream = try connectRawWithRetry(socket_path, 20, 10);

    try writeFrameWithVersion(stream, protocol_version + 1, .hello, 0, &.{});
    var frame = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer frame.deinit(alloc);
    try std.testing.expectEqual(MessageKind.error_message, frame.kind);
    try std.testing.expectEqual(ErrorCode.unsupported_version, try readErrorCode(frame.payload));

    stream.close();
    server_thread.join();
}

test "socket server requires hello before other requests" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/handshake-required", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/handshake-required.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var stream = try connectRawWithRetry(socket_path, 20, 10);

    var payload = std.array_list.Managed(u8).init(alloc);
    defer payload.deinit();
    try appendInt(&payload, u32, 1);
    try encodeDeclareEntry(&payload, 1, .series, "svc.req", "{}", null);
    try writeFrameWithVersion(stream, protocol_version, .declare_batch, 0, payload.items);

    var frame = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer frame.deinit(alloc);
    try std.testing.expectEqual(MessageKind.error_message, frame.kind);
    try std.testing.expectEqual(ErrorCode.handshake_required, try readErrorCode(frame.payload));

    stream.close();
    server_thread.join();
}

test "socket server rejects oversized frames before processing" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/frame-too-large", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/frame-too-large.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, 16 });
    var stream = try connectRawWithRetry(socket_path, 20, 10);

    const large_payload = [_]u8{0} ** 32;
    try writeFrameWithVersion(stream, protocol_version, .append_batch, 0, large_payload[0..]);
    var frame = try readFrameFromStream(alloc, stream, default_max_frame_bytes);
    defer frame.deinit(alloc);
    try std.testing.expectEqual(MessageKind.error_message, frame.kind);
    try std.testing.expectEqual(ErrorCode.frame_too_large, try readErrorCode(frame.payload));

    stream.close();
    server_thread.join();
}

test "socket flush_drain reports timeout when the queue is not yet drained" {
    if (!std.net.has_unix_sockets) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const data_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/flush-timeout", .{tmp.sub_path});
    defer alloc.free(data_path);
    const socket_path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/flush-timeout.sock", .{tmp.sub_path});
    defer alloc.free(socket_path);

    var eng = try Engine.init(alloc, try testConfig(alloc, data_path));
    defer eng.deinit();

    const server_thread = try std.Thread.spawn(.{}, testOneShotServer, .{ eng, socket_path, default_max_frame_bytes });
    var client = try Client.connectWithRetry(alloc, socket_path, 20, 10);

    const declared = try client.declareCachedBatch(&.{
        .{
            .decl_kind = .series,
            .name = "svc.timeout",
            .tags_json = "{}",
        },
    });
    defer alloc.free(declared);

    _ = try client.appendBatch(&.{
        .{ .client_decl_id = declared[0].client_decl_id, .ts = 1, .value = 1.0 },
    });
    try std.testing.expectError(error.Timeout, client.flushAndDrain(0));

    client.deinit();
    server_thread.join();
}
