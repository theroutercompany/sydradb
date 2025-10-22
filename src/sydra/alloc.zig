const std = @import("std");
const build_options = @import("build_options");

const allocator_mode = build_options.allocator_mode;
const use_mimalloc = std.mem.eql(u8, allocator_mode, "mimalloc");
const use_small_pool = std.mem.eql(u8, allocator_mode, "small_pool");

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
} else struct {};

const SmallPoolAllocator = if (use_small_pool) struct {
    const default_alignment = std.mem.Alignment.fromByteUnits(@sizeOf(usize));
    const header_size = default_alignment.toByteUnits();
    const slab_bytes: usize = 64 * 1024;
    const bucket_sizes = [_]usize{ 16, 24, 32, 48, 64, 96, 128, 192, 256 };
    const bucket_count = bucket_sizes.len;
    const fallback_bucket_bounds = [_]usize{ 64, 128, 256, 512, 1024, 2048, 4096, 8192 };
    const fallback_bucket_count = fallback_bucket_bounds.len + 1;

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
            };
        }
    };

    gpa: std.heap.GeneralPurposeAllocator(.{}),
    buckets: [bucket_count]Bucket,
    fallback_allocs: std.atomic.Value(u64),
    fallback_frees: std.atomic.Value(u64),
    fallback_resizes: std.atomic.Value(u64),
    fallback_remaps: std.atomic.Value(u64),
    fallback_sizes: [fallback_bucket_count]std.atomic.Value(u64),

    pub fn init() SmallPoolAllocator {
        var self = SmallPoolAllocator{
            .gpa = std.heap.GeneralPurposeAllocator(.{}){},
            .buckets = undefined,
            .fallback_allocs = std.atomic.Value(u64).init(0),
            .fallback_frees = std.atomic.Value(u64).init(0),
            .fallback_resizes = std.atomic.Value(u64).init(0),
            .fallback_remaps = std.atomic.Value(u64).init(0),
            .fallback_sizes = initFallbackArray(),
        };
        var idx: usize = 0;
        while (idx < bucket_count) : (idx += 1) {
            const size = bucket_sizes[idx];
            const alloc_size = computeAllocSize(size);
            self.buckets[idx] = Bucket.init(size, alloc_size);
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
        if (bucketIndex(len)) |idx| {
            return self.allocBucket(idx, ret_addr);
        }
        _ = self.fallback_allocs.fetchAdd(1, .monotonic);
        self.recordFallback(len);
        return self.backingAllocator().rawAlloc(len, alignment, ret_addr);
    }

    fn allocBucket(self: *SmallPoolAllocator, idx: usize, ret_addr: usize) ?[*]u8 {
        var bucket = &self.buckets[idx];
        bucket.mutex.lock();
        defer bucket.mutex.unlock();

        if (bucket.free_list == null) {
            self.refillBucket(bucket, idx, ret_addr) catch return null;
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
            bucket.mutex.lock();
            if (pointerBelongsToBucket(bucket, ptr)) |block_ptr| {
                const node = @as(*FreeNode, @ptrCast(@alignCast(block_ptr)));
                node.* = .{ .next = bucket.free_list };
                bucket.free_list = node;
                if (bucket.in_use > 0) bucket.in_use -= 1;
                bucket.mutex.unlock();
                return true;
            }
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

    const BucketStats = struct {
        size: usize,
        alloc_size: usize,
        allocations: usize,
        refills: usize,
        in_use: usize,
        high_water: usize,
        slabs: usize,
        free_nodes: usize,
    };

    pub const Stats = struct {
        buckets: [bucket_count]BucketStats,
        fallback_allocs: u64,
        fallback_frees: u64,
        fallback_resizes: u64,
        fallback_remaps: u64,
        fallback_size_buckets: [fallback_bucket_count]u64,
        fallback_size_bounds: [fallback_bucket_count]?usize,
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
        };
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
} else struct {};

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
