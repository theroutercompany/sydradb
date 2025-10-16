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

pub const TypeKind = enum {
    base,
    enum_type,
    domain,
    pseudo,
};

pub const TypeSpec = struct {
    name: []const u8,
    namespace: []const u8,
    oid: u32,
    length: i16,
    by_value: bool,
    kind: TypeKind = .base,
    category: u8 = 'U',
    delimiter: u8 = ',',
    element_type_oid: u32 = 0,
    array_type_oid: u32 = 0,
    base_type_oid: u32 = 0,
    collation_oid: u32 = 0,
    input_regproc: u32 = 0,
    output_regproc: u32 = 0,
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

pub const TypeRow = struct {
    oid: u32,
    typname: []const u8,
    typnamespace: u32,
    typlen: i16,
    typbyval: bool,
    typtype: u8,
    typcategory: u8,
    typdelim: u8,
    typelem: u32,
    typarray: u32,
    typbasetype: u32,
    typcollation: u32,
    typinput: u32,
    typoutput: u32,
};

const empty_type_rows = [_]TypeRow{};

pub const Snapshot = struct {
    namespaces: []NamespaceRow = &empty_namespace_rows,
    classes: []ClassRow = &empty_class_rows,
    attributes: []AttributeRow = &empty_attribute_rows,
    types: []TypeRow = &empty_type_rows,
    owns_memory: bool = false,

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        if (!self.owns_memory) return;
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

        for (self.types) |ty| {
            alloc.free(ty.typname);
        }
        alloc.free(self.types);

        self.* = Snapshot{};
    }
};

pub fn buildSnapshot(
    alloc: std.mem.Allocator,
    namespace_specs: []const NamespaceSpec,
    relation_specs: []const RelationSpec,
    type_specs: []const TypeSpec,
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
        entry_buffer[idx] = entry;
    }

    std.sort.heap(MapEntry, entry_buffer, {}, struct {
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
    @memcpy(rel_entries, relation_specs);

    std.sort.heap(RelationSpec, rel_entries, {}, struct {
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

    var type_entries = std.ArrayList(TypeRow).init(alloc);
    defer type_entries.deinit();

    const type_buffer = try alloc.alloc(TypeSpec, type_specs.len);
    defer alloc.free(type_buffer);
    @memcpy(type_buffer, type_specs);

    std.sort.heap(TypeSpec, type_buffer, {}, struct {
        pub fn lessThan(_: void, lhs: TypeSpec, rhs: TypeSpec) bool {
            if (!std.mem.eql(u8, lhs.namespace, rhs.namespace)) {
                return std.mem.lessThan(u8, lhs.namespace, rhs.namespace);
            }
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    try type_entries.ensureTotalCapacity(type_buffer.len);

    for (type_buffer) |spec| {
        const ns_oid = ns_lookup.get(spec.namespace) orelse return error.MissingNamespace;
        const name_copy = try alloc.dupe(u8, spec.name);
        errdefer alloc.free(name_copy);
        try type_entries.append(.{
            .oid = spec.oid,
            .typname = name_copy,
            .typnamespace = ns_oid,
            .typlen = spec.length,
            .typbyval = spec.by_value,
            .typtype = typeKindChar(spec.kind),
            .typcategory = spec.category,
            .typdelim = spec.delimiter,
            .typelem = spec.element_type_oid,
            .typarray = spec.array_type_oid,
            .typbasetype = spec.base_type_oid,
            .typcollation = spec.collation_oid,
            .typinput = spec.input_regproc,
            .typoutput = spec.output_regproc,
        });
    }

    var attribute_entries = std.ArrayList(AttributeRow).init(alloc);
    defer attribute_entries.deinit();

    const ColEntry = ColumnSpec;
    const col_entries = try alloc.alloc(ColEntry, column_specs.len);
    defer alloc.free(col_entries);
    @memcpy(col_entries, column_specs);

    std.sort.heap(ColEntry, col_entries, {}, struct {
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
        .types = try type_entries.toOwnedSlice(),
        .owns_memory = true,
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

fn typeKindChar(kind: TypeKind) u8 {
    return switch (kind) {
        .base => 'b',
        .enum_type => 'e',
        .domain => 'd',
        .pseudo => 'p',
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
        self.snapshot.deinit(alloc);
        self.snapshot = Snapshot{};
    }

    pub fn load(
        self: *Store,
        alloc: std.mem.Allocator,
        namespace_specs: []const NamespaceSpec,
        relation_specs: []const RelationSpec,
        type_specs: []const TypeSpec,
        column_specs: []const ColumnSpec,
    ) !void {
        const new_snapshot = try buildSnapshot(alloc, namespace_specs, relation_specs, type_specs, column_specs);
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

    pub fn types(self: *Store) []const TypeRow {
        return self.snapshot.types;
    }
};

var global_store: Store = .{};

pub fn global() *Store {
    return &global_store;
}

test "build catalog snapshot" {
    const alloc = std.testing.allocator;
    const namespace_specs = [_]NamespaceSpec{
        .{ .name = "pg_catalog", .owner = 10 },
        .{ .name = "public", .owner = 10 },
    };
    const relation_specs = [_]RelationSpec{
        .{ .namespace = "public", .name = "users", .kind = .table, .has_primary_key = true, .row_estimate = 42 },
        .{ .namespace = "auth", .name = "refresh_tokens", .kind = .table },
        .{ .namespace = "public", .name = "users_view", .kind = .view },
        .{ .namespace = "public", .name = "users_id_seq", .kind = .sequence },
    };

    const type_specs = [_]TypeSpec{
        .{ .name = "int4", .namespace = "pg_catalog", .oid = 23, .length = 4, .by_value = true, .category = 'N' },
        .{ .name = "text", .namespace = "pg_catalog", .oid = 25, .length = -1, .by_value = false, .category = 'S' },
        .{ .name = "_int4", .namespace = "pg_catalog", .oid = 1007, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 23 },
    };

    const column_specs = [_]ColumnSpec{
        .{ .namespace = "public", .relation = "users", .name = "id", .type_oid = 23, .not_null = true, .has_default = true, .identity = .always },
        .{ .namespace = "public", .relation = "users", .name = "name", .type_oid = 25 },
        .{ .namespace = "auth", .relation = "refresh_tokens", .name = "token", .type_oid = 25 },
    };

    var snapshot = try buildSnapshot(alloc, &namespace_specs, &relation_specs, &type_specs, &column_specs);
    defer snapshot.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), snapshot.namespaces.len);
    try std.testing.expectEqual(namespace_oid_base, snapshot.namespaces[0].oid);
    try std.testing.expectEqualStrings("auth", snapshot.namespaces[0].nspname);
    try std.testing.expectEqual(namespace_oid_base + 1, snapshot.namespaces[1].oid);
    try std.testing.expectEqualStrings("pg_catalog", snapshot.namespaces[1].nspname);
    try std.testing.expectEqual(namespace_oid_base + 2, snapshot.namespaces[2].oid);
    try std.testing.expectEqualStrings("public", snapshot.namespaces[2].nspname);

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
    try std.testing.expectEqual(@as(usize, 3), snapshot.types.len);
    try std.testing.expectEqual(@as(u32, 23), snapshot.types[0].oid);
    try std.testing.expectEqualStrings("int4", snapshot.types[0].typname);
    try std.testing.expect(snapshot.types[0].typbyval);
    try std.testing.expectEqual(@as(u8, 'N'), snapshot.types[0].typcategory);
    try std.testing.expectEqual(@as(u32, 25), snapshot.types[1].oid);
    try std.testing.expectEqualStrings("text", snapshot.types[1].typname);
    try std.testing.expectEqual(@as(i16, -1), snapshot.types[1].typlen);
    try std.testing.expect(!snapshot.types[1].typbyval);
    try std.testing.expectEqual(@as(u32, 1007), snapshot.types[2].oid);
    try std.testing.expectEqual(@as(u32, 23), snapshot.types[2].typelem);
}

test "store load lifecycle" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);

    const relations = [_]RelationSpec{.{ .namespace = "public", .name = "users", .kind = .table }};
    const types = [_]TypeSpec{.{ .name = "int4", .namespace = "pg_catalog", .oid = 23, .length = 4, .by_value = true, .category = 'N' }};
    const columns = [_]ColumnSpec{.{ .namespace = "public", .relation = "users", .name = "id", .type_oid = 23 }};

    const ns_full = [_]NamespaceSpec{ .{ .name = "pg_catalog" }, .{ .name = "public" } };

    try store.load(alloc, &ns_full, &relations, &types, &columns);
    try std.testing.expectEqual(@as(usize, 2), store.namespaces().len);
    try std.testing.expectEqual(@as(usize, 1), store.classes().len);
    try std.testing.expectEqualStrings("pg_catalog", store.namespaces()[0].nspname);
    try std.testing.expectEqualStrings("public", store.namespaces()[1].nspname);
    try std.testing.expectEqualStrings("users", store.classes()[0].relname);
    try std.testing.expectEqual(@as(usize, 1), store.attributes().len);
    try std.testing.expectEqual(@as(usize, 1), store.types().len);
}
