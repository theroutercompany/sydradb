const std = @import("std");
const build_options = @import("build_options");

const allocator_mode = build_options.allocator_mode;
const use_mimalloc = std.mem.eql(u8, allocator_mode, "mimalloc");
const use_small_pool = std.mem.eql(u8, allocator_mode, "small_pool");

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

    const FreeNode = struct {
        next: ?*FreeNode,
    };

    const Bucket = struct {
        size: usize,
        alloc_size: usize,
        free_list: ?*FreeNode,
        slabs: std.ArrayListUnmanaged([]u8),
        mutex: std.Thread.Mutex,

        fn init(size: usize, alloc_size: usize) Bucket {
            return .{
                .size = size,
                .alloc_size = alloc_size,
                .free_list = null,
                .slabs = .{},
                .mutex = std.Thread.Mutex{},
            };
        }
    };

    gpa: std.heap.GeneralPurposeAllocator(.{}),
    buckets: [bucket_count]Bucket,

    pub fn init() SmallPoolAllocator {
        var self = SmallPoolAllocator{
            .gpa = std.heap.GeneralPurposeAllocator(.{}){},
            .buckets = undefined,
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
            return self.backingAllocator().rawAlloc(len, alignment, ret_addr);
        }
        if (bucketIndex(len)) |idx| {
            return self.allocBucket(idx, ret_addr);
        }
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
        return self.backingAllocator().rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self = @as(*SmallPoolAllocator, @ptrCast(@alignCast(ctx)));
        if (self.pointerBelongs(memory.ptr)) {
            return null;
        }
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
} else struct {};

pub const AllocatorHandle = if (use_small_pool) struct {
    pool: SmallPoolAllocator,

    pub fn init() AllocatorHandle {
        return .{ .pool = SmallPoolAllocator.init() };
    }

    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return self.pool.allocator();
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
