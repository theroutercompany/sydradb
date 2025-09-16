const std = @import("std");

const empty_namespace_rows = [_]NamespaceRow{};
const empty_class_rows = [_]ClassRow{};

pub const namespace_oid_base: u32 = 11000;
pub const relation_oid_base: u32 = 22000;

pub const NamespaceSpec = struct {
    name: []const u8,
    owner: u32 = 10,
};

pub const RelationKind = enum {
    table,
    index,
    view,
    sequence,
};

pub const Persistence = enum {
    permanent,
    temporary,
    unlogged,
};

pub const RelationSpec = struct {
    namespace: []const u8,
    name: []const u8,
    kind: RelationKind,
    persistence: Persistence = .permanent,
    has_primary_key: bool = false,
    row_estimate: f64 = 0,
    is_partition: bool = false,
    toast_relation_oid: ?u32 = null,
};

pub const IdentityKind = enum {
    none,
    always,
    by_default,
};

pub const GeneratedKind = enum {
    none,
    stored,
};

pub const ColumnSpec = struct {
    namespace: []const u8,
    relation: []const u8,
    name: []const u8,
    type_oid: u32,
    position: ?i16 = null,
    not_null: bool = false,
    has_default: bool = false,
    is_dropped: bool = false,
    type_length: i16 = -1,
    type_modifier: i32 = -1,
    identity: IdentityKind = .none,
    generated: GeneratedKind = .none,
    dimensions: i32 = 0,
};

pub const NamespaceRow = struct {
    oid: u32,
    nspname: []const u8,
    nspowner: u32,
};

pub const ClassRow = struct {
    oid: u32,
    relname: []const u8,
    relnamespace: u32,
    relkind: u8,
    relpersistence: u8,
    reltuples: f64,
    relhaspkey: bool,
    relispartition: bool,
    reltoastrelid: u32,
};

pub const AttributeRow = struct {
    attrelid: u32,
    attname: []const u8,
    atttypid: u32,
    attnum: i16,
    attnotnull: bool,
    atthasdef: bool,
    attisdropped: bool,
    attlen: i16,
    atttypmod: i32,
    attidentity: u8,
    attgenerated: u8,
    attndims: i32,
};

const empty_attribute_rows = [_]AttributeRow{};

pub const Snapshot = struct {
    namespaces: []NamespaceRow = &empty_namespace_rows,
    classes: []ClassRow = &empty_class_rows,
    attributes: []AttributeRow = &empty_attribute_rows,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        for (self.namespaces) |ns| {
            alloc.free(ns.nspname);
        }
        alloc.free(self.namespaces);

        for (self.classes) |cls| {
            alloc.free(cls.relname);
        }
        alloc.free(self.classes);

        for (self.attributes) |attr| {
            alloc.free(attr.attname);
        }
        alloc.free(self.attributes);

        self.* = Snapshot{};
    }
};

pub fn buildSnapshot(
    alloc: std.mem.Allocator,
    namespace_specs: []const NamespaceSpec,
    relation_specs: []const RelationSpec,
    column_specs: []const ColumnSpec,
) !Snapshot {
    var ns_map = std.StringArrayHashMap(NamespaceSpec).init(alloc);
    defer ns_map.deinit();

    for (namespace_specs) |spec| {
        const name_copy = try alloc.dupe(u8, spec.name);
        errdefer alloc.free(name_copy);
        if (ns_map.contains(name_copy)) {
            alloc.free(name_copy);
            continue;
        }
        try ns_map.put(name_copy, spec);
    }

    for (relation_specs) |spec| {
        if (ns_map.get(spec.namespace) != null) continue;
        const name_copy = try alloc.dupe(u8, spec.namespace);
        errdefer alloc.free(name_copy);
        try ns_map.put(name_copy, NamespaceSpec{ .name = name_copy });
    }

    var namespace_entries = std.ArrayList(NamespaceRow).init(alloc);
    defer namespace_entries.deinit();

    var ns_lookup = std.StringArrayHashMap(u32).init(alloc);
    defer ns_lookup.deinit();

    const MapEntry = std.StringArrayHashMap(NamespaceSpec).Entry;

    var entry_buffer = try alloc.alloc(MapEntry, ns_map.count());
    defer alloc.free(entry_buffer);

    var idx: usize = 0;
    var it = ns_map.iterator();
    while (it.next()) |entry| : (idx += 1) {
        entry_buffer[idx] = entry.*;
    }

    std.sort.sort(MapEntry, entry_buffer, {}, struct {
        pub fn lessThan(_: void, lhs: MapEntry, rhs: MapEntry) bool {
            return std.mem.lessThan(u8, lhs.key_ptr.*, rhs.key_ptr.*);
        }
    }.lessThan);

    try namespace_entries.ensureTotalCapacity(entry_buffer.len);

    idx = 0;
    while (idx < entry_buffer.len) : (idx += 1) {
        const entry = entry_buffer[idx];
        const offset: u32 = @intCast(idx);
        const oid = namespace_oid_base + offset;
        const name_ptr = entry.key_ptr.*;
        try namespace_entries.append(.{
            .oid = oid,
            .nspname = name_ptr,
            .nspowner = entry.value_ptr.*.owner,
        });
        try ns_lookup.put(name_ptr, oid);
    }

    var class_entries = std.ArrayList(ClassRow).init(alloc);
    defer class_entries.deinit();

    const rel_entries = try alloc.alloc(RelationSpec, relation_specs.len);
    defer alloc.free(rel_entries);
    std.mem.copy(RelationSpec, rel_entries, relation_specs);

    std.sort.sort(RelationSpec, rel_entries, {}, struct {
        pub fn lessThan(_: void, lhs: RelationSpec, rhs: RelationSpec) bool {
            if (std.mem.eql(u8, lhs.namespace, rhs.namespace)) {
                return std.mem.lessThan(u8, lhs.name, rhs.name);
            }
            return std.mem.lessThan(u8, lhs.namespace, rhs.namespace);
        }
    }.lessThan);

    try class_entries.ensureTotalCapacity(rel_entries.len);

    var rel_index: usize = 0;
    while (rel_index < rel_entries.len) : (rel_index += 1) {
        const spec = rel_entries[rel_index];
        const ns_oid = ns_lookup.get(spec.namespace) orelse {
            return error.MissingNamespace;
        };
        const rel_offset: u32 = @intCast(rel_index);
        const oid = relation_oid_base + rel_offset;
        const relname_copy = try alloc.dupe(u8, spec.name);
        errdefer alloc.free(relname_copy);
        try class_entries.append(.{
            .oid = oid,
            .relname = relname_copy,
            .relnamespace = ns_oid,
            .relkind = relationKindChar(spec.kind),
            .relpersistence = persistenceChar(spec.persistence),
            .reltuples = spec.row_estimate,
            .relhaspkey = spec.has_primary_key,
            .relispartition = spec.is_partition,
            .reltoastrelid = spec.toast_relation_oid orelse 0,
        });
    }

    var attribute_entries = std.ArrayList(AttributeRow).init(alloc);
    defer attribute_entries.deinit();

    const ColEntry = ColumnSpec;
    const col_entries = try alloc.alloc(ColEntry, column_specs.len);
    defer alloc.free(col_entries);
    std.mem.copy(ColEntry, col_entries, column_specs);

    std.sort.sort(ColEntry, col_entries, {}, struct {
        pub fn lessThan(_: void, lhs: ColEntry, rhs: ColEntry) bool {
            if (!std.mem.eql(u8, lhs.namespace, rhs.namespace)) {
                return std.mem.lessThan(u8, lhs.namespace, rhs.namespace);
            }
            if (!std.mem.eql(u8, lhs.relation, rhs.relation)) {
                return std.mem.lessThan(u8, lhs.relation, rhs.relation);
            }
            if (lhs.position) |lp| {
                if (rhs.position) |rp| return lp < rp;
                return true;
            } else if (rhs.position != null) {
                return false;
            }
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    try attribute_entries.ensureTotalCapacity(col_entries.len);

    var attnum_tracker = std.AutoHashMap(u32, i16).init(alloc);
    defer attnum_tracker.deinit();

    var col_index: usize = 0;
    while (col_index < col_entries.len) : (col_index += 1) {
        const spec = col_entries[col_index];
        const ns_oid = ns_lookup.get(spec.namespace) orelse return error.MissingNamespace;
        const rel_oid = try findRelationOid(class_entries.items, ns_oid, spec.relation);
        const attnum = try nextAttnum(&attnum_tracker, rel_oid, spec.position);
        const attname_copy = try alloc.dupe(u8, spec.name);
        errdefer alloc.free(attname_copy);
        try attribute_entries.append(.{
            .attrelid = rel_oid,
            .attname = attname_copy,
            .atttypid = spec.type_oid,
            .attnum = attnum,
            .attnotnull = spec.not_null,
            .atthasdef = spec.has_default,
            .attisdropped = spec.is_dropped,
            .attlen = spec.type_length,
            .atttypmod = spec.type_modifier,
            .attidentity = identityChar(spec.identity),
            .attgenerated = generatedChar(spec.generated),
            .attndims = spec.dimensions,
        });
    }

    return Snapshot{
        .namespaces = try namespace_entries.toOwnedSlice(),
        .classes = try class_entries.toOwnedSlice(),
        .attributes = try attribute_entries.toOwnedSlice(),
    };
}

fn relationKindChar(kind: RelationKind) u8 {
    return switch (kind) {
        .table => 'r',
        .index => 'i',
        .view => 'v',
        .sequence => 'S',
    };
}

fn persistenceChar(persistence: Persistence) u8 {
    return switch (persistence) {
        .permanent => 'p',
        .temporary => 't',
        .unlogged => 'u',
    };
}

fn identityChar(kind: IdentityKind) u8 {
    return switch (kind) {
        .none => ' ',
        .always => 'a',
        .by_default => 'd',
    };
}

fn generatedChar(kind: GeneratedKind) u8 {
    return switch (kind) {
        .none => ' ',
        .stored => 's',
    };
}

fn findRelationOid(classes: []const ClassRow, ns_oid: u32, relname: []const u8) !u32 {
    for (classes) |row| {
        if (row.relnamespace == ns_oid and std.mem.eql(u8, row.relname, relname)) {
            return row.oid;
        }
    }
    return error.MissingRelation;
}

fn nextAttnum(map: *std.AutoHashMap(u32, i16), rel_oid: u32, override: ?i16) !i16 {
    if (override) |val| {
        const entry = try map.getOrPut(rel_oid);
        entry.value_ptr.* = val;
        return val;
    }
    const entry = try map.getOrPut(rel_oid);
    if (!entry.found_existing) {
        entry.value_ptr.* = 1;
        return 1;
    }
    entry.value_ptr.* += 1;
    return entry.value_ptr.*;
}

pub const Store = struct {
    snapshot: Snapshot = .{},

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        if (self.snapshot.namespaces.ptr != empty_namespace_rows.ptr or self.snapshot.namespaces.len != 0) {
            self.snapshot.deinit(alloc);
        }
        self.snapshot = Snapshot{};
    }

    pub fn load(
        self: *Store,
        alloc: std.mem.Allocator,
        namespace_specs: []const NamespaceSpec,
        relation_specs: []const RelationSpec,
        column_specs: []const ColumnSpec,
    ) !void {
        const new_snapshot = try buildSnapshot(alloc, namespace_specs, relation_specs, column_specs);
        self.deinit(alloc);
        self.snapshot = new_snapshot;
    }

    pub fn namespaces(self: *Store) []const NamespaceRow {
        return self.snapshot.namespaces;
    }

    pub fn classes(self: *Store) []const ClassRow {
        return self.snapshot.classes;
    }

    pub fn attributes(self: *Store) []const AttributeRow {
        return self.snapshot.attributes;
    }
};

var global_store: Store = .{};

pub fn global() *Store {
    return &global_store;
}

test "build catalog snapshot" {
    const alloc = std.testing.allocator;
    const namespace_specs = [_]NamespaceSpec{
        .{ .name = "public", .owner = 10 },
    };
    const relation_specs = [_]RelationSpec{
        .{ .namespace = "public", .name = "users", .kind = .table, .has_primary_key = true, .row_estimate = 42 },
        .{ .namespace = "auth", .name = "refresh_tokens", .kind = .table },
        .{ .namespace = "public", .name = "users_view", .kind = .view },
        .{ .namespace = "public", .name = "users_id_seq", .kind = .sequence },
    };

    const column_specs = [_]ColumnSpec{
        .{ .namespace = "public", .relation = "users", .name = "id", .type_oid = 23, .not_null = true, .has_default = true, .identity = .always },
        .{ .namespace = "public", .relation = "users", .name = "name", .type_oid = 25 },
        .{ .namespace = "auth", .relation = "refresh_tokens", .name = "token", .type_oid = 25 },
    };

    var snapshot = try buildSnapshot(alloc, &namespace_specs, &relation_specs, &column_specs);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), snapshot.namespaces.len);
    try std.testing.expectEqual(namespace_oid_base, snapshot.namespaces[0].oid);
    try std.testing.expectEqualStrings("auth", snapshot.namespaces[0].nspname);
    try std.testing.expectEqual(namespace_oid_base + 1, snapshot.namespaces[1].oid);
    try std.testing.expectEqualStrings("public", snapshot.namespaces[1].nspname);

    try std.testing.expectEqual(@as(usize, 4), snapshot.classes.len);
    try std.testing.expectEqual(relation_oid_base, snapshot.classes[0].oid);
    try std.testing.expectEqualStrings("refresh_tokens", snapshot.classes[0].relname);
    try std.testing.expectEqual(namespace_oid_base, snapshot.classes[0].relnamespace);
    try std.testing.expect(snapshot.classes[0].relhaspkey == false);
    try std.testing.expectEqual('r', snapshot.classes[0].relkind);

    try std.testing.expectEqualStrings("users", snapshot.classes[1].relname);
    try std.testing.expect(snapshot.classes[1].relhaspkey);
    try std.testing.expectEqual('r', snapshot.classes[1].relkind);
    try std.testing.expectEqual(@as(f64, 42), snapshot.classes[1].reltuples);

    try std.testing.expectEqual('v', snapshot.classes[2].relkind);
    try std.testing.expectEqual('S', snapshot.classes[3].relkind);

    try std.testing.expectEqual(@as(usize, 3), snapshot.attributes.len);
    try std.testing.expectEqual(snapshot.classes[1].oid, snapshot.attributes[0].attrelid);
    try std.testing.expectEqual(@as(i16, 1), snapshot.attributes[0].attnum);
    try std.testing.expect(snapshot.attributes[0].attnotnull);
    try std.testing.expectEqual('a', snapshot.attributes[0].attidentity);
    try std.testing.expectEqualStrings("name", snapshot.attributes[1].attname);
    try std.testing.expectEqual(@as(i16, 2), snapshot.attributes[1].attnum);
    try std.testing.expectEqualStrings("token", snapshot.attributes[2].attname);
    try std.testing.expectEqual(snapshot.classes[0].oid, snapshot.attributes[2].attrelid);
}

test "store load lifecycle" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);

    const namespaces = [_]NamespaceSpec{.{ .name = "public" }};
    const relations = [_]RelationSpec{.{ .namespace = "public", .name = "users", .kind = .table }};
    const columns = [_]ColumnSpec{.{ .namespace = "public", .relation = "users", .name = "id", .type_oid = 23 }};

    try store.load(alloc, &namespaces, &relations, &columns);
    try std.testing.expectEqual(@as(usize, 1), store.namespaces().len);
    try std.testing.expectEqual(@as(usize, 1), store.classes().len);
    try std.testing.expectEqualStrings("public", store.namespaces()[0].nspname);
    try std.testing.expectEqualStrings("users", store.classes()[0].relname);
    try std.testing.expectEqual(@as(usize, 1), store.attributes().len);
}
