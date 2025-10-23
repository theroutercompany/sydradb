const std = @import("std");
const build_options = @import("build_options");
const slab_shard = @import("alloc/slab_shard.zig");

const allocator_mode = build_options.allocator_mode;
const use_mimalloc = std.mem.eql(u8, allocator_mode, "mimalloc");
const use_small_pool = std.mem.eql(u8, allocator_mode, "small_pool");
const configured_shard_count: u32 = build_options.allocator_shards;

pub const mode = allocator_mode;
pub const is_mimalloc = use_mimalloc;
pub const is_small_pool = use_small_pool;

comptime {
    if (!std.mem.eql(u8, allocator_mode, "default") and !use_mimalloc and !use_small_pool) {
        @compileError("unknown allocator-mode: " ++ allocator_mode);
    }
}

const MimallocAllocator = if (use_mimalloc) struct {
    const c = @cImport({
        @cInclude("mimalloc.h");
    });

    fn bytesFromAlignment(alignment: std.mem.Alignment) usize {
        const raw = alignment.toByteUnits();
        return if (raw == 0) 1 else raw;
    }

    fn allocFn(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        if (len == 0) return null;
        const align_bytes = bytesFromAlignment(alignment);
        const ptr = c.mi_malloc_aligned(len, align_bytes);
        if (ptr == null) return null;
        return @as([*]u8, @ptrCast(ptr.?));
    }

    fn resizeFn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        // In-place growth/shrink unsupported; let caller handle via remap.
        return false;
    }

    fn remapFn(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
        if (new_len == 0) return null;
        const align_bytes = bytesFromAlignment(alignment);
        const ptr = c.mi_realloc_aligned(memory.ptr, new_len, align_bytes);
        if (ptr == null) return null;
        return @as([*]u8, @ptrCast(ptr.?));
    }

    fn freeFn(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        if (memory.len == 0) return;
        c.mi_free(memory.ptr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn init() MimallocAllocator {
        return .{};
    }

    pub fn allocator(self: *MimallocAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &vtable,
        };
    }
} else struct {
    pub const ThreadShardState = struct {};
    pub const ShardManager = struct {};
};

const SmallPoolAllocator = if (use_small_pool) struct {
    const default_alignment = std.mem.Alignment.fromByteUnits(@sizeOf(usize));
    const header_size = default_alignment.toByteUnits();
    const slab_bytes: usize = 64 * 1024;
    const bucket_sizes = [_]usize{ 16, 24, 32, 48, 64, 96, 128, 192, 256 };
    const bucket_count = bucket_sizes.len;
    const fallback_bucket_bounds = [_]usize{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
    const fallback_bucket_count = fallback_bucket_bounds.len + 1;
    const lock_wait_threshold_ns: i64 = 1_000;
    const shard_classes_table = buildSlabClasses();
    const max_shard_size = shard_classes_table[shard_classes_table.len - 1].size;

    const ThreadShardState = struct {
        manager: ?*ShardManager = null,
        shard_index: u32 = 0,
    };

    const ShardManager = struct {
        allocator: std.mem.Allocator,
        shards: []slab_shard.Shard,
        assign_counter: std.atomic.Value(u32),

        pub fn init(backing: std.mem.Allocator, config: slab_shard.ShardConfig, shard_count: usize) !ShardManager {
            std.debug.assert(shard_count > 0);
            var shards = try backing.alloc(slab_shard.Shard, shard_count);
            var init_count: usize = 0;
            errdefer {
                var idx: usize = 0;
                while (idx < init_count) : (idx += 1) {
                    shards[idx].deinit();
                }
                backing.free(shards);
            }
            while (init_count < shard_count) : (init_count += 1) {
                shards[init_count] = try slab_shard.Shard.init(backing, config);
                shards[init_count].assignOwner();
            }
            return .{
                .allocator = backing,
                .shards = shards,
                .assign_counter = std.atomic.Value(u32).init(0),
            };
        }

        pub fn deinit(self: *ShardManager) void {
            var idx: usize = 0;
            while (idx < self.shards.len) : (idx += 1) {
                self.shards[idx].deinit();
            }
            self.allocator.free(self.shards);
            const state = getThreadState();
            if (state.manager == self) {
                state.manager = null;
                state.shard_index = 0;
            }
        }

        fn getThreadState() *ThreadShardState {
            return &small_pool_tls_state;
        }

        fn assignShardIndex(self: *ShardManager) u32 {
            if (self.shards.len == 0) return 0;
            const ticket = self.assign_counter.fetchAdd(1, .monotonic);
            const width: u32 = @intCast(self.shards.len);
            return ticket % width;
        }

        pub fn currentShard(self: *ShardManager) *slab_shard.Shard {
            const state = getThreadState();
            if (state.manager != self) {
                state.manager = self;
                state.shard_index = self.assignShardIndex();
            }
            if (state.shard_index >= self.shards.len) {
                state.shard_index = self.assignShardIndex();
            }
            return &self.shards[state.shard_index];
        }

        pub fn freeLocal(_: *ShardManager, ptr: [*]u8) bool {
            if (slab_shard.Shard.owningShard(ptr)) |owner| {
                return owner.free(ptr);
            }
            return false;
        }

        pub fn freeDeferred(_: *ShardManager, ptr: [*]u8) bool {
            if (slab_shard.Shard.owningShard(ptr)) |owner| {
                return owner.freeDeferred(ptr);
            }
            return false;
        }

        pub fn collectGarbage(self: *ShardManager) void {
            var idx: usize = 0;
            while (idx < self.shards.len) : (idx += 1) {
                self.shards[idx].collectGarbage();
            }
        }

        pub fn enterEpoch(self: *ShardManager) u64 {
            return self.currentShard().currentEpoch();
        }

        pub fn leaveEpoch(self: *ShardManager, observed: u64) void {
            self.currentShard().observeEpoch(observed);
        }

        pub fn advanceEpoch(self: *ShardManager) u64 {
            return self.currentShard().advanceEpoch();
        }
    };

    const FreeNode = struct {
        next: ?*FreeNode,
    };

    const Bucket = struct {
        size: usize,
        alloc_size: usize,
        free_list: ?*FreeNode,
        slabs: std.ArrayListUnmanaged([]u8),
        mutex: std.Thread.Mutex,
        allocations: usize,
        refills: usize,
        in_use: usize,
        high_water: usize,
        lock_wait_ns_total: std.atomic.Value(u64),
        lock_hold_ns_total: std.atomic.Value(u64),
        lock_acquisitions: std.atomic.Value(u64),
        lock_contention: std.atomic.Value(u64),

        fn init(size: usize, alloc_size: usize) Bucket {
            return .{
                .size = size,
                .alloc_size = alloc_size,
                .free_list = null,
                .slabs = .{},
                .mutex = std.Thread.Mutex{},
                .allocations = 0,
                .refills = 0,
                .in_use = 0,
                .high_water = 0,
                .lock_wait_ns_total = std.atomic.Value(u64).init(0),
                .lock_hold_ns_total = std.atomic.Value(u64).init(0),
                .lock_acquisitions = std.atomic.Value(u64).init(0),
                .lock_contention = std.atomic.Value(u64).init(0),
            };
        }
    };

    fn buildSlabClasses() [bucket_count]slab_shard.SlabClass {
        var classes: [bucket_count]slab_shard.SlabClass = undefined;
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            const size = bucket_sizes[idx];
            const alloc_size = computeAllocSize(size);
            var per_slab = slab_bytes / alloc_size;
            if (per_slab == 0) per_slab = 1;
            classes[idx] = .{
                .size = size,
                .alloc_size = alloc_size,
                .objects_per_slab = per_slab,
            };
        }
        return classes;
    }

    fn shardConfig() slab_shard.ShardConfig {
        return .{
            .classes = shard_classes_table[0..],
            .slab_bytes = slab_bytes,
        };
    }

    gpa: std.heap.GeneralPurposeAllocator(.{}),
    buckets: [bucket_count]Bucket,
    fallback_allocs: std.atomic.Value(u64),
    fallback_frees: std.atomic.Value(u64),
    fallback_resizes: std.atomic.Value(u64),
    fallback_remaps: std.atomic.Value(u64),
    fallback_sizes: [fallback_bucket_count]std.atomic.Value(u64),
    shard_manager: ?ShardManager,
    shard_alloc_hits: std.atomic.Value(u64),
    shard_alloc_misses: std.atomic.Value(u64),

    pub fn init() SmallPoolAllocator {
        var self = SmallPoolAllocator{
            .gpa = std.heap.GeneralPurposeAllocator(.{}){},
            .buckets = undefined,
            .fallback_allocs = std.atomic.Value(u64).init(0),
            .fallback_frees = std.atomic.Value(u64).init(0),
            .fallback_resizes = std.atomic.Value(u64).init(0),
            .fallback_remaps = std.atomic.Value(u64).init(0),
            .fallback_sizes = initFallbackArray(),
            .shard_manager = null,
            .shard_alloc_hits = std.atomic.Value(u64).init(0),
            .shard_alloc_misses = std.atomic.Value(u64).init(0),
        };
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            const size = bucket_sizes[idx];
            const alloc_size = computeAllocSize(size);
            self.buckets[idx] = Bucket.init(size, alloc_size);
        }
        if (configured_shard_count > 0) {
            const shard_count = @as(usize, configured_shard_count);
            if (shard_count != 0) {
                const maybe_manager = ShardManager.init(self.backingAllocator(), shardConfig(), shard_count) catch null;
                if (maybe_manager) |manager| {
                    self.shard_manager = manager;
                }
            }
        }
        return self;
    }

    fn computeAllocSize(size: usize) usize {
        return std.mem.alignForward(usize, size + header_size, default_alignment.toByteUnits());
    }

    fn bucketIndex(len: usize) ?usize {
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            if (len <= bucket_sizes[idx]) return idx;
        }
        return null;
    }

    fn backingAllocator(self: *SmallPoolAllocator) std.mem.Allocator {
        return self.gpa.allocator();
    }

    fn allocInternal(self: *SmallPoolAllocator, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        if (len == 0) return null;
        const align_bytes = alignment.toByteUnits();
        if (align_bytes > default_alignment.toByteUnits()) {
            _ = self.fallback_allocs.fetchAdd(1, .monotonic);
            self.recordFallback(len);
            return self.backingAllocator().rawAlloc(len, alignment, ret_addr);
        }
        if (self.shard_manager) |*manager| {
            if (len <= max_shard_size) {
                const shard = manager.currentShard();
                if (shard.allocate(len, alignment, ret_addr)) |ptr| {
                    _ = self.shard_alloc_hits.fetchAdd(1, .monotonic);
                    return ptr;
                } else {
                    _ = self.shard_alloc_misses.fetchAdd(1, .monotonic);
                    manager.collectGarbage();
                }
            }
        }
        if (bucketIndex(len)) |idx| {
            return self.allocBucket(idx, ret_addr);
        }
        _ = self.fallback_allocs.fetchAdd(1, .monotonic);
        self.recordFallback(len);
        return self.backingAllocator().rawAlloc(len, alignment, ret_addr);
    }

    fn allocBucket(self: *SmallPoolAllocator, idx: usize, ret_addr: usize) ?[*]u8 {
        var bucket = &self.buckets[idx];
        const wait_start = std.time.nanoTimestamp();
        bucket.mutex.lock();
        const acquired_ns = std.time.nanoTimestamp();
        const wait_ns = acquired_ns - wait_start;
        _ = bucket.lock_acquisitions.fetchAdd(1, .monotonic);
        _ = bucket.lock_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_ns)), .monotonic);
        if (wait_ns > lock_wait_threshold_ns) {
            _ = bucket.lock_contention.fetchAdd(1, .monotonic);
        }
        var hold_start_ns = acquired_ns;
        defer {
            const release_ns = std.time.nanoTimestamp();
            const hold_ns = release_ns - hold_start_ns;
            _ = bucket.lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
            bucket.mutex.unlock();
        }

        if (bucket.free_list == null) {
            self.refillBucket(bucket, idx, ret_addr) catch return null;
            hold_start_ns = std.time.nanoTimestamp();
        }
        const node = bucket.free_list orelse return null;
        bucket.free_list = node.next;
        bucket.allocations += 1;
        bucket.in_use += 1;
        if (bucket.in_use > bucket.high_water) bucket.high_water = bucket.in_use;
        const block_ptr = @as([*]u8, @ptrCast(node));
        return block_ptr + header_size;
    }

    fn refillBucket(self: *SmallPoolAllocator, bucket: *Bucket, idx: usize, ret_addr: usize) !void {
        _ = idx;
        var blocks_per_slab = slab_bytes / bucket.alloc_size;
        if (blocks_per_slab == 0) blocks_per_slab = 1;
        const total_bytes = bucket.alloc_size * blocks_per_slab;
        const backing = self.backingAllocator();
        const memory = backing.rawAlloc(total_bytes, default_alignment, ret_addr) orelse return error.OutOfMemory;
        const slab = memory[0..total_bytes];
        try bucket.slabs.append(backing, slab);
        bucket.refills += 1;
        var offset: usize = 0;
        while (offset < total_bytes) : (offset += bucket.alloc_size) {
            const node = @as(*FreeNode, @ptrCast(@alignCast(memory + offset)));
            node.* = .{ .next = bucket.free_list };
            bucket.free_list = node;
        }
    }

    fn pointerBelongsToBucket(bucket: *Bucket, ptr: [*]u8) ?[*]u8 {
        const ptr_val = @intFromPtr(ptr);
        const slabs = bucket.slabs.items;
        for (slabs) |slab| {
            const base = @intFromPtr(slab.ptr);
            const end = base + slab.len;
            if (ptr_val < base + header_size or ptr_val >= end) continue;
            const rel = ptr_val - (base + header_size);
            if (rel % bucket.alloc_size != 0) continue;
            const block_idx = rel / bucket.alloc_size;
            const block_start_val = base + block_idx * bucket.alloc_size;
            return @as([*]u8, @ptrFromInt(block_start_val));
        }
        return null;
    }

    fn freeSmall(self: *SmallPoolAllocator, memory: []u8) bool {
        const ptr = memory.ptr;
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            var bucket = &self.buckets[idx];
            const wait_start = std.time.nanoTimestamp();
            bucket.mutex.lock();
            const acquired_ns = std.time.nanoTimestamp();
            const wait_ns = acquired_ns - wait_start;
            _ = bucket.lock_acquisitions.fetchAdd(1, .monotonic);
            _ = bucket.lock_wait_ns_total.fetchAdd(@as(u64, @intCast(wait_ns)), .monotonic);
            if (wait_ns > lock_wait_threshold_ns) {
                _ = bucket.lock_contention.fetchAdd(1, .monotonic);
            }
            const hold_start_ns = acquired_ns;
            if (pointerBelongsToBucket(bucket, ptr)) |block_ptr| {
                const node = @as(*FreeNode, @ptrCast(@alignCast(block_ptr)));
                node.* = .{ .next = bucket.free_list };
                bucket.free_list = node;
                if (bucket.in_use > 0) bucket.in_use -= 1;
                const release_ns = std.time.nanoTimestamp();
                const hold_ns = release_ns - hold_start_ns;
                _ = bucket.lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
                bucket.mutex.unlock();
                return true;
            }
            const release_ns = std.time.nanoTimestamp();
            const hold_ns = release_ns - hold_start_ns;
            _ = bucket.lock_hold_ns_total.fetchAdd(@as(u64, @intCast(hold_ns)), .monotonic);
            bucket.mutex.unlock();
        }
        return false;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = @as(*SmallPoolAllocator, @ptrCast(@alignCast(ctx)));
        return self.allocInternal(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self = @as(*SmallPoolAllocator, @ptrCast(@alignCast(ctx)));
        if (self.pointerBelongs(memory.ptr)) {
            return false;
        }
        _ = self.fallback_resizes.fetchAdd(1, .monotonic);
        self.recordFallback(new_len);
        return self.backingAllocator().rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = @as(*SmallPoolAllocator, @ptrCast(@alignCast(ctx)));
        if (self.pointerBelongs(memory.ptr)) {
            return null;
        }
        _ = self.fallback_remaps.fetchAdd(1, .monotonic);
        self.recordFallback(new_len);
        return self.backingAllocator().rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn pointerBelongs(self: *SmallPoolAllocator, ptr: [*]u8) bool {
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            var bucket = &self.buckets[idx];
            bucket.mutex.lock();
            const belongs = pointerBelongsToBucket(bucket, ptr) != null;
            bucket.mutex.unlock();
            if (belongs) return true;
        }
        return false;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self = @as(*SmallPoolAllocator, @ptrCast(@alignCast(ctx)));
        if (memory.len == 0) return;
        if (self.shard_manager) |*manager| {
            const ptr = @as([*]u8, memory.ptr);
            if (manager.freeLocal(ptr)) return;
            if (manager.freeDeferred(ptr)) {
                manager.collectGarbage();
                return;
            }
        }
        if (self.freeSmall(memory)) return;
        _ = self.fallback_frees.fetchAdd(1, .monotonic);
        self.recordFallback(memory.len);
        self.backingAllocator().rawFree(memory, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn allocator(self: *SmallPoolAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *SmallPoolAllocator) void {
        if (self.shard_manager) |*manager| {
            manager.deinit();
            self.shard_manager = null;
        }
        const backing = self.backingAllocator();
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            var bucket = &self.buckets[idx];
            for (bucket.slabs.items) |slab| {
                backing.rawFree(slab, default_alignment, 0);
            }
            bucket.slabs.deinit(backing);
        }
        _ = self.gpa.deinit();
    }

    pub fn enterEpoch(self: *SmallPoolAllocator) ?u64 {
        if (self.shard_manager) |*manager| {
            return manager.enterEpoch();
        }
        return null;
    }

    pub fn leaveEpoch(self: *SmallPoolAllocator, observed: u64) void {
        if (self.shard_manager) |*manager| {
            manager.leaveEpoch(observed);
        }
    }

    pub fn advanceEpoch(self: *SmallPoolAllocator) ?u64 {
        if (self.shard_manager) |*manager| {
            return manager.advanceEpoch();
        }
        return null;
    }

    const BucketStats = struct {
        size: usize,
        alloc_size: usize,
        allocations: usize,
        refills: usize,
        in_use: usize,
        high_water: usize,
        slabs: usize,
        free_nodes: usize,
        lock_wait_ns_total: u64,
        lock_hold_ns_total: u64,
        lock_acquisitions: u64,
        lock_contention: u64,
    };

    pub const Stats = struct {
        buckets: [bucket_count]BucketStats,
        fallback_allocs: u64,
        fallback_frees: u64,
        fallback_resizes: u64,
        fallback_remaps: u64,
        fallback_size_buckets: [fallback_bucket_count]u64,
        fallback_size_bounds: [fallback_bucket_count]?usize,
        shard_enabled: bool,
        shard_count: usize,
        shard_alloc_hits: u64,
        shard_alloc_misses: u64,
        shard_deferred_total: usize,
        shard_current_epoch: u64,
        shard_min_epoch: u64,
    };

    fn countFreeList(head: ?*FreeNode) usize {
        var cnt: usize = 0;
        var node = head;
        while (node) |n| {
            cnt += 1;
            node = n.next;
        }
        return cnt;
    }

    pub fn snapshotStats(self: *SmallPoolAllocator) Stats {
        var stats = Stats{
            .buckets = undefined,
            .fallback_allocs = self.fallback_allocs.load(.monotonic),
            .fallback_frees = self.fallback_frees.load(.monotonic),
            .fallback_resizes = self.fallback_resizes.load(.monotonic),
            .fallback_remaps = self.fallback_remaps.load(.monotonic),
            .fallback_size_buckets = undefined,
            .fallback_size_bounds = undefined,
            .shard_enabled = false,
            .shard_count = 0,
            .shard_alloc_hits = self.shard_alloc_hits.load(.monotonic),
            .shard_alloc_misses = self.shard_alloc_misses.load(.monotonic),
            .shard_deferred_total = 0,
            .shard_current_epoch = 0,
            .shard_min_epoch = std.math.maxInt(u64),
        };
        if (self.shard_manager) |*manager| {
            stats.shard_enabled = true;
            stats.shard_count = manager.shards.len;
            var min_epoch: u64 = std.math.maxInt(u64);
            var max_epoch: u64 = 0;
            var deferred_total: usize = 0;
            for (manager.shards) |*shard| {
                const summary = shard.summary();
                deferred_total += summary.deferred_total;
                if (summary.current_epoch > max_epoch) max_epoch = summary.current_epoch;
                if (summary.min_observed_epoch < min_epoch) min_epoch = summary.min_observed_epoch;
            }
            stats.shard_deferred_total = deferred_total;
            stats.shard_current_epoch = max_epoch;
            stats.shard_min_epoch = if (min_epoch == std.math.maxInt(u64)) 0 else min_epoch;
        } else {
            stats.shard_min_epoch = 0;
        }
        var bucket_idx: usize = 0;
        while (bucket_idx < fallback_bucket_count) : (bucket_idx += 1) {
            stats.fallback_size_buckets[bucket_idx] = self.fallback_sizes[bucket_idx].load(.monotonic);
            stats.fallback_size_bounds[bucket_idx] = if (bucket_idx < fallback_bucket_bounds.len)
                fallback_bucket_bounds[bucket_idx]
            else
                null;
        }
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            var bucket = &self.buckets[idx];
            bucket.mutex.lock();
            const slabs_len = bucket.slabs.items.len;
            const free_nodes = countFreeList(bucket.free_list);
            stats.buckets[idx] = .{
                .size = bucket.size,
                .alloc_size = bucket.alloc_size,
                .allocations = bucket.allocations,
                .refills = bucket.refills,
                .in_use = bucket.in_use,
                .high_water = bucket.high_water,
                .slabs = slabs_len,
                .free_nodes = free_nodes,
                .lock_wait_ns_total = bucket.lock_wait_ns_total.load(.monotonic),
                .lock_hold_ns_total = bucket.lock_hold_ns_total.load(.monotonic),
                .lock_acquisitions = bucket.lock_acquisitions.load(.monotonic),
                .lock_contention = bucket.lock_contention.load(.monotonic),
            };
            bucket.mutex.unlock();
        }
        return stats;
    }

    fn initFallbackArray() [fallback_bucket_count]std.atomic.Value(u64) {
        var arr: [fallback_bucket_count]std.atomic.Value(u64) = undefined;
        var idx: usize = 0;
        while (idx < fallback_bucket_count) : (idx += 1) {
            arr[idx] = std.atomic.Value(u64).init(0);
        }
        return arr;
    }

    fn recordFallback(self: *SmallPoolAllocator, size: usize) void {
        const bucket_idx = fallbackBucketIndex(size);
        _ = self.fallback_sizes[bucket_idx].fetchAdd(1, .monotonic);
    }

    fn fallbackBucketIndex(size: usize) usize {
        var idx: usize = 0;
        while (idx < fallback_bucket_bounds.len) : (idx += 1) {
            if (size <= fallback_bucket_bounds[idx]) return idx;
        }
        return fallback_bucket_bounds.len;
    }
} else struct {
    pub const ThreadShardState = struct {};
    pub const ShardManager = struct {};
};

threadlocal var small_pool_tls_state: SmallPoolAllocator.ThreadShardState = .{};

pub const AllocatorHandle = if (use_small_pool) struct {
    pool: SmallPoolAllocator,

    pub fn init() AllocatorHandle {
        return .{ .pool = SmallPoolAllocator.init() };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.pool.allocator();
    }

    pub fn snapshotSmallPoolStats(self: *AllocatorHandle) SmallPoolAllocator.Stats {
        return self.pool.snapshotStats();
    }

    pub fn enterEpoch(self: *AllocatorHandle) ?u64 {
        return self.pool.enterEpoch();
    }

    pub fn leaveEpoch(self: *AllocatorHandle, observed: u64) void {
        self.pool.leaveEpoch(observed);
    }

    pub fn advanceEpoch(self: *AllocatorHandle) ?u64 {
        return self.pool.advanceEpoch();
    }

    pub fn deinit(self: *AllocatorHandle) void {
        self.pool.deinit();
    }
} else if (use_mimalloc) struct {
    mimalloc: MimallocAllocator,

    pub fn init() AllocatorHandle {
        return .{ .mimalloc = MimallocAllocator.init() };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.mimalloc.allocator();
    }

    pub fn deinit(self: *AllocatorHandle) void {
        _ = self;
    }
} else struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),

    pub fn init() AllocatorHandle {
        return .{ .gpa = std.heap.GeneralPurposeAllocator(.{}){} };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.gpa.allocator();
    }

    pub fn deinit(self: *AllocatorHandle) void {
        _ = self.gpa.deinit();
    }
};

test "shard manager assigns per-thread shards" {
    if (!use_small_pool) return;

    var manager = try SmallPoolAllocator.ShardManager.init(std.testing.allocator, SmallPoolAllocator.shardConfig(), 2);
    defer manager.deinit();

    const main_shard = manager.currentShard();
    try std.testing.expect(main_shard == manager.currentShard());

    const Context = struct {
        manager: *SmallPoolAllocator.ShardManager,
        shard: ?*slab_shard.Shard = null,
    };

    var ctx = Context{ .manager = &manager, .shard = null };
    const thread_fn = struct {
        fn run(arg: *Context) void {
            arg.shard = arg.manager.currentShard();
        }
    }.run;

    var worker = try std.Thread.spawn(.{}, thread_fn, .{&ctx});
    worker.join();
    try std.testing.expect(ctx.shard != null);
    try std.testing.expect(ctx.shard.? != main_shard);
}
