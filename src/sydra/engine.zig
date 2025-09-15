const std = @import("std");
const cfg = @import("config.zig");
const types = @import("types.zig");
const manifest_mod = @import("storage/manifest.zig");
const wal_mod = @import("storage/wal.zig");
const segment_mod = @import("storage/segment.zig");
const tags_mod = @import("storage/tags.zig");
const retention = @import("storage/retention.zig");

pub const Engine = struct {
    alloc: std.mem.Allocator,
    config: cfg.Config,
    data_dir: std.fs.Dir,
    wal: wal_mod.WAL,
    mem: MemTable,
    manifest: manifest_mod.Manifest,
    tags: tags_mod.TagIndex,
    flush_timer_ms: u32,
    writer_thread: ?std.Thread = null,
    stop_flag: bool = false,
    queue: *Queue,

    pub const MemTable = struct {
        series: std.AutoHashMap(types.SeriesId, std.ArrayList(types.Point)),
        bytes: usize,
        pub fn init(alloc: std.mem.Allocator) MemTable {
            return .{ .series = std.AutoHashMap(types.SeriesId, std.ArrayList(types.Point)).init(alloc), .bytes = 0 };
        }
        pub fn deinit(self: *MemTable) void {
            var it = self.series.valueIterator();
            while (it.next()) |lst| lst.deinit();
            self.series.deinit();
        }
    };

    pub const IngestItem = struct {
        series_id: types.SeriesId,
        ts: i64,
        value: f64,
        // raw tags json for future tag index updates
        tags_json: []const u8,
    };

    pub const Queue = struct {
        alloc: std.mem.Allocator,
        mu: std.Thread.Mutex = .{},
        cv: std.Thread.Condition = .{},
        buf: std.ArrayList(IngestItem),
        closed: bool = false,
        pub fn init(alloc: std.mem.Allocator) !*Queue {
            const q = try alloc.create(Queue);
            q.* = .{ .alloc = alloc, .buf = try std.ArrayList(IngestItem).initCapacity(alloc, 0) };
            return q;
        }
        pub fn deinit(self: *Queue) void {
            self.buf.deinit();
        }
        pub fn push(self: *Queue, item: IngestItem) !void {
            self.mu.lock();
            defer self.mu.unlock();
            if (self.closed) return error.Closed;
            try self.buf.append(self.alloc, item);
            self.cv.signal();
        }
        pub fn pop(self: *Queue) ?IngestItem {
            self.mu.lock();
            defer self.mu.unlock();
            while (self.buf.items.len == 0 and !self.closed) {
                self.cv.timedWait(&self.mu, std.time.ns_per_ms * 100) catch break;
            }
            if (self.buf.items.len == 0) return null;
            return self.buf.orderedRemove(0);
        }
        pub fn close(self: *Queue) void {
            self.mu.lock();
            self.closed = true;
            self.mu.unlock();
            self.cv.broadcast();
        }
    };

    pub fn init(alloc: std.mem.Allocator, config: cfg.Config) !*Engine {
        var dir = try std.fs.cwd().openDir(config.data_dir, .{ .iterate = true });
        // Create if missing
        dir.close();
        try std.fs.cwd().makePath(config.data_dir);
        const data_dir = try std.fs.cwd().openDir(config.data_dir, .{ .iterate = true });
        const wal = try wal_mod.WAL.open(alloc, data_dir, config.fsync);
        var engine = try alloc.create(Engine);
        engine.* = .{
            .alloc = alloc,
            .config = config,
            .data_dir = data_dir,
            .wal = wal,
            .mem = MemTable.init(alloc),
            .manifest = try manifest_mod.Manifest.loadOrInit(alloc, data_dir),
            .tags = try tags_mod.TagIndex.loadOrInit(alloc, data_dir),
            .flush_timer_ms = config.flush_interval_ms,
            .queue = try Queue.init(alloc),
        };
        engine.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{engine});
        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.stop_flag = true;
        self.queue.close();
        if (self.writer_thread) |t| t.join();
        self.mem.deinit();
        self.manifest.deinit();
        self.tags.deinit();
        self.wal.close();
        self.data_dir.close();
        self.alloc.destroy(self.queue);
        self.config.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn ingest(self: *Engine, item: IngestItem) !void {
        try self.queue.push(item);
    }

    fn writerLoop(self: *Engine) void {
        inline fn sleepMs(ms: u64) void {
            comptime if (@hasDecl(std.time, "sleep")) {
                std.time.sleep(ms * std.time.ns_per_ms);
            } else {
                std.Thread.sleep(ms * std.time.ns_per_ms);
            }
        }
        var last_flush = std.time.milliTimestamp();
        var last_sync = last_flush;
        while (!self.stop_flag) {
            if (self.queue.pop()) |it| {
                // WAL append
                self.wal.append(it.series_id, it.ts, it.value) catch {};
                // Memtable insert
                var gop = self.mem.series.getOrPut(it.series_id) catch continue;
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(types.Point).initCapacity(self.alloc, 0) catch {
                        // drop this point if we can't allocate
                        continue;
                    };
                }
                _ = gop.value_ptr.append(self.alloc, .{ .ts = it.ts, .value = it.value }) catch {};
                self.mem.bytes += @sizeOf(types.Point);
            } else sleepMs(10);

            const now = std.time.milliTimestamp();
            if (self.mem.bytes >= self.config.memtable_max_bytes or (now - last_flush) >= self.flush_timer_ms) {
                flushMemtable(self) catch {};
                last_flush = now;
                // apply retention best-effort after flush
                retention.apply(self.data_dir, &self.manifest, self.config.retention_days) catch {};
            }
            // fsync policy: interval
            if (self.config.fsync == .interval and (now - last_sync) >= self.flush_timer_ms) {
                self.wal.file.sync() catch {};
                last_sync = now;
            }
        }
        // final flush
        flushMemtable(self) catch {};
    }

    fn flushMemtable(self: *Engine) !void {
        // write per-series per-hour segments, update manifest, then clear memtable
        var it = self.mem.series.iterator();
        while (it.next()) |entry| {
            const sid = entry.key_ptr.*;
            var arr = entry.value_ptr.*;
            if (arr.items.len == 0) continue;
            std.sort.block(types.Point, arr.items, {}, struct {
                fn lessThan(_: void, a: types.Point, b: types.Point) bool { return a.ts < b.ts; }
            }.lessThan);
            // Partition by hour (UTC)
            var start_idx: usize = 0;
            while (start_idx < arr.items.len) {
                const hour = hourBucket(arr.items[start_idx].ts);
                var end_idx = start_idx + 1;
                while (end_idx < arr.items.len and hourBucket(arr.items[end_idx].ts) == hour) : (end_idx += 1) {}
                const slice = arr.items[start_idx..end_idx];
                // write segment
                const seg_path = try segment_mod.writeSegment(self.alloc, self.data_dir, sid, hour, slice);
                const c: u32 = @intCast(slice.len);
                try self.manifest.add(self.data_dir, sid, hour, slice[0].ts, slice[slice.len - 1].ts, c, seg_path);
                self.alloc.free(seg_path);
                start_idx = end_idx;
            }
            arr.clearRetainingCapacity();
        }
        self.mem.bytes = 0;
        // rotate WAL optionally
        self.wal.rotateIfNeeded() catch {};
        // persist tag index snapshot (best-effort)
        self.tags.save(self.data_dir) catch {};
    }

    fn hourBucket(ts: i64) i64 {
        const secs_per_hour: i64 = 3600;
        return (@divTrunc(ts, secs_per_hour)) * secs_per_hour;
    }

    pub fn queryRange(self: *Engine, series_id: types.SeriesId, start_ts: i64, end_ts: i64, out: *std.ArrayList(types.Point)) !void {
        try segment_mod.queryRange(self.alloc, self.data_dir, &self.manifest, series_id, start_ts, end_ts, out);
    }

    pub fn noteTags(self: *Engine, series_id: types.SeriesId, tags: []const u8) void {
        // tags is expected to be a JSON object; we parse and update tag→series mapping
        var p = std.json.Parser.init(self.alloc, false);
        defer p.deinit();
        var tree = p.parse(tags) catch return;
        defer tree.deinit();
        if (tree.root != .object) return;
        var it = tree.root.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .string) {
                var keybuf = try std.ArrayList(u8).initCapacity(self.alloc, 0);
                defer keybuf.deinit();
                keybuf.writer().print("{s}={s}", .{ e.key_ptr.*, e.value_ptr.string }) catch continue;
                const key = keybuf.toOwnedSlice() catch continue;
                defer self.alloc.free(key);
                self.tags.add(key, series_id) catch {};
            }
        }
    }
};
