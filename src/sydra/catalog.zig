const std = @import("std");
const compat = @import("compat.zig");

pub const NamespaceInfo = struct {
    name: []const u8,
    owner: u32 = 10,
};

pub const RelationInfo = struct {
    namespace: []const u8,
    name: []const u8,
    kind: compat.catalog.RelationKind,
    persistence: compat.catalog.Persistence = .permanent,
    has_primary_key: bool = false,
    row_estimate: f64 = 0,
    is_partition: bool = false,
    toast_relation_oid: ?u32 = null,
};

pub const TypeInfo = struct {
    name: []const u8,
    namespace: []const u8,
    oid: u32,
    length: i16,
    by_value: bool,
    kind: compat.catalog.TypeKind = .base,
    category: u8 = 'U',
    delimiter: u8 = ',',
    element_type_oid: u32 = 0,
    array_type_oid: u32 = 0,
    base_type_oid: u32 = 0,
    collation_oid: u32 = 0,
    input_regproc: u32 = 0,
    output_regproc: u32 = 0,
};

pub const ColumnInfo = struct {
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
    identity: compat.catalog.IdentityKind = .none,
    generated: compat.catalog.GeneratedKind = .none,
    dimensions: i32 = 0,
};

pub const Adapter = struct {
    namespaces: []const NamespaceInfo,
    relations: []const RelationInfo,
    types: []const TypeInfo,
    columns: []const ColumnInfo,
};

const default_namespaces = [_]NamespaceInfo{
    .{ .name = "pg_catalog" },
    .{ .name = "public" },
};

const default_relations = [_]RelationInfo{
    .{ .namespace = "pg_catalog", .name = "pg_type", .kind = .table },
};

const default_types = [_]TypeInfo{
    .{ .name = "bool", .namespace = "pg_catalog", .oid = 16, .length = 1, .by_value = true, .category = 'B', .array_type_oid = 1000 },
    .{ .name = "int2", .namespace = "pg_catalog", .oid = 21, .length = 2, .by_value = true, .category = 'N', .array_type_oid = 1005 },
    .{ .name = "int8", .namespace = "pg_catalog", .oid = 20, .length = 8, .by_value = true, .category = 'N', .array_type_oid = 1016 },
    .{ .name = "int4", .namespace = "pg_catalog", .oid = 23, .length = 4, .by_value = true, .category = 'N', .array_type_oid = 1007 },
    .{ .name = "float4", .namespace = "pg_catalog", .oid = 700, .length = 4, .by_value = true, .category = 'N', .array_type_oid = 1021 },
    .{ .name = "float8", .namespace = "pg_catalog", .oid = 701, .length = 8, .by_value = true, .category = 'N', .array_type_oid = 1022 },
    .{ .name = "numeric", .namespace = "pg_catalog", .oid = 1700, .length = -1, .by_value = false, .category = 'N', .array_type_oid = 1231 },
    .{ .name = "text", .namespace = "pg_catalog", .oid = 25, .length = -1, .by_value = false, .category = 'S', .array_type_oid = 1009 },
    .{ .name = "uuid", .namespace = "pg_catalog", .oid = 2950, .length = 16, .by_value = true, .category = 'U', .array_type_oid = 2951 },
    .{ .name = "timestamp", .namespace = "pg_catalog", .oid = 1114, .length = 8, .by_value = true, .category = 'D', .array_type_oid = 1115 },
    .{ .name = "timestamptz", .namespace = "pg_catalog", .oid = 1184, .length = 8, .by_value = true, .category = 'D', .array_type_oid = 1185 },
    .{ .name = "date", .namespace = "pg_catalog", .oid = 1082, .length = 4, .by_value = true, .category = 'D', .array_type_oid = 1182 },
    .{ .name = "time", .namespace = "pg_catalog", .oid = 1083, .length = 8, .by_value = true, .category = 'D', .array_type_oid = 1183 },
    .{ .name = "jsonb", .namespace = "pg_catalog", .oid = 3802, .length = -1, .by_value = false, .category = 'U', .array_type_oid = 3807 },
    .{ .name = "_bool", .namespace = "pg_catalog", .oid = 1000, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 16 },
    .{ .name = "_int2", .namespace = "pg_catalog", .oid = 1005, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 21 },
    .{ .name = "_int8", .namespace = "pg_catalog", .oid = 1016, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 20 },
    .{ .name = "_int4", .namespace = "pg_catalog", .oid = 1007, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 23 },
    .{ .name = "_float4", .namespace = "pg_catalog", .oid = 1021, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 700 },
    .{ .name = "_float8", .namespace = "pg_catalog", .oid = 1022, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 701 },
    .{ .name = "_numeric", .namespace = "pg_catalog", .oid = 1231, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 1700 },
    .{ .name = "_text", .namespace = "pg_catalog", .oid = 1009, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 25 },
    .{ .name = "_uuid", .namespace = "pg_catalog", .oid = 2951, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 2950 },
    .{ .name = "_timestamp", .namespace = "pg_catalog", .oid = 1115, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 1114 },
    .{ .name = "_timestamptz", .namespace = "pg_catalog", .oid = 1185, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 1184 },
    .{ .name = "_date", .namespace = "pg_catalog", .oid = 1182, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 1082 },
    .{ .name = "_time", .namespace = "pg_catalog", .oid = 1183, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 1083 },
    .{ .name = "_jsonb", .namespace = "pg_catalog", .oid = 3807, .length = -1, .by_value = false, .category = 'A', .element_type_oid = 3802 },
};

const default_columns = [_]ColumnInfo{
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "oid", .type_oid = 23, .not_null = true },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typname", .type_oid = 25, .not_null = true },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typlen", .type_oid = 21, .not_null = true },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typbyval", .type_oid = 16, .not_null = true },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typtype", .type_oid = 25 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typcategory", .type_oid = 25 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typdelim", .type_oid = 25 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typelem", .type_oid = 23 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typarray", .type_oid = 23 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typbasetype", .type_oid = 23 },
    .{ .namespace = "pg_catalog", .relation = "pg_type", .name = "typcollation", .type_oid = 23 },
};

pub fn defaultAdapter() Adapter {
    return Adapter{
        .namespaces = &default_namespaces,
        .relations = &default_relations,
        .types = &default_types,
        .columns = &default_columns,
    };
}

fn toNamespaceSpecs(alloc: std.mem.Allocator, infos: []const NamespaceInfo) ![]compat.catalog.NamespaceSpec {
    if (infos.len == 0) return &[_]compat.catalog.NamespaceSpec{};
    const specs = try alloc.alloc(compat.catalog.NamespaceSpec, infos.len);
    for (infos, specs) |info, *spec| {
        spec.* = .{ .name = info.name, .owner = info.owner };
    }
    return specs;
}

fn toRelationSpecs(alloc: std.mem.Allocator, infos: []const RelationInfo) ![]compat.catalog.RelationSpec {
    if (infos.len == 0) return &[_]compat.catalog.RelationSpec{};
    const specs = try alloc.alloc(compat.catalog.RelationSpec, infos.len);
    for (infos, specs) |info, *spec| {
        spec.* = .{
            .namespace = info.namespace,
            .name = info.name,
            .kind = info.kind,
            .persistence = info.persistence,
            .has_primary_key = info.has_primary_key,
            .row_estimate = info.row_estimate,
            .is_partition = info.is_partition,
            .toast_relation_oid = info.toast_relation_oid,
        };
    }
    return specs;
}

fn toTypeSpecs(alloc: std.mem.Allocator, infos: []const TypeInfo) ![]compat.catalog.TypeSpec {
    if (infos.len == 0) return &[_]compat.catalog.TypeSpec{};
    const specs = try alloc.alloc(compat.catalog.TypeSpec, infos.len);
    for (infos, specs) |info, *spec| {
        spec.* = .{
            .name = info.name,
            .namespace = info.namespace,
            .oid = info.oid,
            .length = info.length,
            .by_value = info.by_value,
            .kind = info.kind,
            .category = info.category,
            .delimiter = info.delimiter,
            .element_type_oid = info.element_type_oid,
            .array_type_oid = info.array_type_oid,
            .base_type_oid = info.base_type_oid,
            .collation_oid = info.collation_oid,
            .input_regproc = info.input_regproc,
            .output_regproc = info.output_regproc,
        };
    }
    return specs;
}

fn toColumnSpecs(alloc: std.mem.Allocator, infos: []const ColumnInfo) ![]compat.catalog.ColumnSpec {
    if (infos.len == 0) return &[_]compat.catalog.ColumnSpec{};
    const specs = try alloc.alloc(compat.catalog.ColumnSpec, infos.len);
    for (infos, specs) |info, *spec| {
        spec.* = .{
            .namespace = info.namespace,
            .relation = info.relation,
            .name = info.name,
            .type_oid = info.type_oid,
            .position = info.position,
            .not_null = info.not_null,
            .has_default = info.has_default,
            .is_dropped = info.is_dropped,
            .type_length = info.type_length,
            .type_modifier = info.type_modifier,
            .identity = info.identity,
            .generated = info.generated,
            .dimensions = info.dimensions,
        };
    }
    return specs;
}

pub fn loadIntoStore(store: *compat.catalog.Store, alloc: std.mem.Allocator, adapter: Adapter) !void {
    const ns_specs = try toNamespaceSpecs(alloc, adapter.namespaces);
    defer if (ns_specs.len != 0) alloc.free(ns_specs);

    const rel_specs = try toRelationSpecs(alloc, adapter.relations);
    defer if (rel_specs.len != 0) alloc.free(rel_specs);

    const type_specs = try toTypeSpecs(alloc, adapter.types);
    defer if (type_specs.len != 0) alloc.free(type_specs);

    const col_specs = try toColumnSpecs(alloc, adapter.columns);
    defer if (col_specs.len != 0) alloc.free(col_specs);

    try store.load(alloc, ns_specs, rel_specs, type_specs, col_specs);
}

pub fn refreshGlobal(alloc: std.mem.Allocator, adapter: Adapter) !void {
    try loadIntoStore(compat.catalog.global(), alloc, adapter);
}

pub fn bootstrap(alloc: std.mem.Allocator) !void {
    try refreshGlobal(alloc, defaultAdapter());
}

test "adapter loads into store" {
    const alloc = std.testing.allocator;
    var store = compat.catalog.Store{};
    defer store.deinit(alloc);

    const adapter = Adapter{
        .namespaces = &[_]NamespaceInfo{
            .{ .name = "pg_catalog" },
            .{ .name = "public" },
        },
        .relations = &[_]RelationInfo{
            .{ .namespace = "public", .name = "widgets", .kind = .table, .has_primary_key = true },
            .{ .namespace = "pg_catalog", .name = "pg_type", .kind = .table },
        },
        .types = &[_]TypeInfo{
            .{ .name = "int4", .namespace = "pg_catalog", .oid = 23, .length = 4, .by_value = true, .category = 'N' },
            .{ .name = "text", .namespace = "pg_catalog", .oid = 25, .length = -1, .by_value = false, .category = 'S' },
        },
        .columns = &[_]ColumnInfo{
            .{ .namespace = "public", .relation = "widgets", .name = "id", .type_oid = 23, .not_null = true, .has_default = true, .identity = .always },
            .{ .namespace = "public", .relation = "widgets", .name = "name", .type_oid = 25 },
        },
    };

    try loadIntoStore(&store, alloc, adapter);

    try std.testing.expectEqual(@as(usize, 2), store.namespaces().len);
    try std.testing.expectEqualStrings("pg_catalog", store.namespaces()[0].nspname);
    try std.testing.expectEqualStrings("public", store.namespaces()[1].nspname);

    try std.testing.expectEqual(@as(usize, 2), store.classes().len);
    try std.testing.expectEqualStrings("widgets", store.classes()[0].relname);
    try std.testing.expect(store.classes()[0].relhaspkey);

    try std.testing.expectEqual(@as(usize, 2), store.attributes().len);
    try std.testing.expectEqualStrings("id", store.attributes()[0].attname);
    try std.testing.expectEqual(@as(i16, 1), store.attributes()[0].attnum);

    try std.testing.expectEqual(@as(usize, 2), store.types().len);
}

test "bootstrap seeds global defaults" {
    const alloc = std.testing.allocator;
    try bootstrap(alloc);
    const store = compat.catalog.global();
    try std.testing.expect(store.namespaces().len >= 2);
    try std.testing.expect(store.types().len >= 4);
    const types = store.types();
    var found_int4 = false;
    var found_text_array = false;
    var found_timestamptz = false;
    var found_jsonb = false;
    for (types) |ty| {
        if (std.mem.eql(u8, ty.typname, "int4")) {
            try std.testing.expectEqual(@as(u32, 1007), ty.typarray);
            found_int4 = true;
        } else if (std.mem.eql(u8, ty.typname, "_text")) {
            try std.testing.expectEqual(@as(u32, 25), ty.typelem);
            found_text_array = true;
        } else if (std.mem.eql(u8, ty.typname, "timestamptz")) {
            try std.testing.expectEqual(@as(u32, 1185), ty.typarray);
            found_timestamptz = true;
        } else if (std.mem.eql(u8, ty.typname, "jsonb")) {
            try std.testing.expectEqual(@as(u32, 3807), ty.typarray);
            found_jsonb = true;
        }
    }
    try std.testing.expect(found_int4);
    try std.testing.expect(found_text_array);
    try std.testing.expect(found_timestamptz);
    try std.testing.expect(found_jsonb);
}
