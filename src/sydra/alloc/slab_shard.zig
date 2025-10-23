const std = @import("std");

const default_alignment = std.mem.Alignment.fromByteUnits(@sizeOf(usize));
const header_size = default_alignment.toByteUnits();

pub const SlabClass = struct {
    size: usize,
    alloc_size: usize,
    objects_per_slab: usize,
};

const Slab = struct {
    memory: []u8,
};

const FreeNode = struct {
    class_state: *ClassState,
    next: ?*FreeNode,
    epoch: u64 = 0,
};

const ClassState = struct {
    info: SlabClass,
    slabs: std.ArrayListUnmanaged(Slab) = .{},
    free_list: ?*FreeNode = null,
    allocations: usize = 0,
    in_use: usize = 0,
    high_water: usize = 0,
    deferred: std.atomic.Value(?*FreeNode) = std.atomic.Value(?*FreeNode).init(null),
    owner: ?*Shard = null,
};

pub const SlabStats = struct {
    class: SlabClass,
    slabs: usize,
    free_nodes: usize,
    allocated: usize,
    in_use: usize,
    high_water: usize,
    deferred: usize,
    current_epoch: u64,
    min_observed_epoch: u64,
};

pub const ShardConfig = struct {
    classes: []const SlabClass,
    slab_bytes: usize,
};

pub const Summary = struct {
    deferred_total: usize,
    current_epoch: u64,
    min_observed_epoch: u64,
};

pub const Shard = struct {
    allocator: std.mem.Allocator,
    config: ShardConfig,
    states: []ClassState,
    global_epoch: std.atomic.Value(u64),
    thread_epoch: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, config: ShardConfig) !Shard {
        const states = try allocator.alloc(ClassState, config.classes.len);
        for (states, 0..) |*state, idx| {
            state.* = .{ .info = config.classes[idx] };
        }
        return .{
            .allocator = allocator,
            .config = config,
            .states = states,
            .global_epoch = std.atomic.Value(u64).init(1),
            .thread_epoch = std.atomic.Value(u64).init(0),
        };
    }

    pub fn assignOwner(self: *Shard) void {
        for (self.states) |*state| {
            state.owner = self;
        }
    }

    pub fn deinit(self: *Shard) void {
        for (self.states) |*state| {
            for (state.slabs.items) |slab| {
                self.allocator.rawFree(slab.memory, default_alignment, 0);
            }
            state.slabs.deinit(self.allocator);
        }
        self.allocator.free(self.states);
    }

    pub fn allocate(self: *Shard, size: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const state = self.findState(size) orelse return null;
        if (alignment.toByteUnits() > default_alignment.toByteUnits()) return null;
        if (state.free_list == null) {
            self.refill(state, ret_addr) catch return null;
        }
        const node = state.free_list orelse return null;
        state.free_list = node.next;
        state.allocations += 1;
        state.in_use += 1;
        if (state.in_use > state.high_water) state.high_water = state.in_use;
        const base_ptr = @as([*]u8, @ptrCast(node));
        return base_ptr + header_size;
    }

    pub fn free(self: *Shard, ptr: [*]u8) bool {
        const base = ptr - header_size;
        const node = @as(*FreeNode, @ptrCast(@alignCast(base)));
        const state = node.class_state;
        if (!self.ownsState(state)) return false;
        node.next = state.free_list;
        state.free_list = node;
        if (state.in_use > 0) state.in_use -= 1;
        return true;
    }

    pub fn freeDeferred(self: *Shard, ptr: [*]u8) bool {
        const base = ptr - header_size;
        const node = @as(*FreeNode, @ptrCast(@alignCast(base)));
        const state = node.class_state;
        if (!self.ownsState(state)) return false;
        const epoch = self.global_epoch.load(.monotonic);
        node.epoch = epoch;
        var expected = state.deferred.load(.monotonic);
        while (true) {
            node.next = expected;
            const result = state.deferred.compareExchangeWeak(expected, node, .monotonic, .monotonic);
            switch (result) {
                .success => return true,
                .failure => |actual| {
                    expected = actual;
                    continue;
                },
            }
        }
    }

    pub fn collectGarbage(self: *Shard) void {
        const min_epoch = self.thread_epoch.load(.monotonic);
        for (self.states) |*state| {
            while (true) {
                const head = state.deferred.load(.monotonic);
                const node = head orelse break;
                if (node.epoch > min_epoch) break;
                const next = node.next;
                if (state.deferred.compareExchangeWeak(head, next, .monotonic, .monotonic) == .success) {
                    node.next = state.free_list;
                    state.free_list = node;
                    if (state.in_use > 0) state.in_use -= 1;
                }
            }
        }
    }

    pub fn currentEpoch(self: *Shard) u64 {
        return self.global_epoch.load(.monotonic);
    }

    pub fn advanceEpoch(self: *Shard) u64 {
        return self.global_epoch.fetchAdd(1, .monotonic) + 1;
    }

    pub fn observeEpoch(self: *Shard, epoch: u64) void {
        self.thread_epoch.store(epoch, .monotonic);
    }

    pub fn summary(self: *Shard) Summary {
        var deferred_total: usize = 0;
        for (self.states) |*state| {
            const head = state.deferred.load(.monotonic);
            deferred_total += countFreeList(head);
        }
        return .{
            .deferred_total = deferred_total,
            .current_epoch = self.global_epoch.load(.monotonic),
            .min_observed_epoch = self.thread_epoch.load(.monotonic),
        };
    }

    pub fn snapshot(self: *Shard, allocator: std.mem.Allocator) ![]SlabStats {
        const stats = try allocator.alloc(SlabStats, self.states.len);
        errdefer allocator.free(stats);
        for (self.states, 0..) |*state, idx| {
            const deferred_head = state.deferred.load(.monotonic);
            stats[idx] = .{
                .class = state.info,
                .slabs = state.slabs.items.len,
                .free_nodes = countFreeList(state.free_list),
                .allocated = state.allocations,
                .in_use = state.in_use,
                .high_water = state.high_water,
                .deferred = countFreeList(deferred_head),
                .current_epoch = self.global_epoch.load(.monotonic),
                .min_observed_epoch = self.thread_epoch.load(.monotonic),
            };
        }
        return stats;
    }

    fn refill(self: *Shard, state: *ClassState, ret_addr: usize) !void {
        const total_bytes = state.info.alloc_size * state.info.objects_per_slab;
        const memory = try self.allocator.rawAlloc(total_bytes, default_alignment, ret_addr);
        const slab = Slab{ .memory = memory };
        try state.slabs.append(self.allocator, slab);
        var offset: usize = 0;
        while (offset + state.info.alloc_size <= total_bytes) : (offset += state.info.alloc_size) {
            const block = memory[offset..][0..state.info.alloc_size];
            const node = @as(*FreeNode, @ptrCast(@alignCast(block.ptr)));
            node.class_state = state;
            node.next = state.free_list;
            state.free_list = node;
        }
    }

    fn findState(self: *Shard, size: usize) ?*ClassState {
        for (self.states) |*state| {
            if (size <= state.info.size) return state;
        }
        return null;
    }

    fn ownsState(self: *Shard, state: *ClassState) bool {
        for (self.states) |*candidate| {
            if (candidate == state) return true;
        }
        return false;
    }

    pub fn owningShard(ptr: [*]u8) ?*Shard {
        const base = ptr - header_size;
        const node = @as(*FreeNode, @ptrCast(@alignCast(base)));
        return node.class_state.owner;
    }
};

fn countFreeList(node: ?*FreeNode) usize {
    var count: usize = 0;
    var cursor = node;
    while (cursor) |n| {
        count += 1;
        cursor = n.next;
    }
    return count;
}

test "shard allocates and frees blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base_classes = [_]SlabClass{
        .{ .size = 32, .alloc_size = 32 + header_size, .objects_per_slab = 16 },
    };
    var shard = try Shard.init(arena.allocator(), .{
        .classes = &base_classes,
        .slab_bytes = 64 * 1024,
    });
    defer shard.deinit();

    const ptr = shard.allocate(16, default_alignment, @returnAddress()) orelse return error.TestUnexpectedResult;
    try std.testing.expect(shard.free(ptr));
}

test "owningShard returns correct shard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const base_classes = [_]SlabClass{
        .{ .size = 32, .alloc_size = 32 + header_size, .objects_per_slab = 16 },
    };
    var shard = try Shard.init(arena.allocator(), .{
        .classes = &base_classes,
        .slab_bytes = 64 * 1024,
    });
    defer shard.deinit();
    shard.assignOwner();

    const ptr = shard.allocate(8, default_alignment, @returnAddress()) orelse return error.TestUnexpectedResult;
    const owner = Shard.owningShard(ptr) orelse return error.TestUnexpectedResult;
    try std.testing.expect(owner == &shard);
    try std.testing.expect(shard.free(ptr));
}
