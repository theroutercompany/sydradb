const std = @import("std");

pub const Expect = union(enum) {
    success: Success,
    failure: Failure,
};

pub const Success = struct {
    sydraql: []const u8,
};

pub const Failure = struct {
    sqlstate: []const u8,
    message: []const u8,
};

pub const Case = struct {
    name: []const u8,
    sql: []const u8,
    expect: Expect,
    notes: []const u8,
};

pub const CaseList = struct {
    alloc: std.mem.Allocator,
    cases: []Case,

    pub fn deinit(self: *CaseList) void {
        for (self.cases) |case| {
            self.alloc.free(case.name);
            self.alloc.free(case.sql);
            self.alloc.free(case.notes);
            switch (case.expect) {
                .success => |s| self.alloc.free(s.sydraql),
                .failure => |f| {
                    self.alloc.free(f.sqlstate);
                    self.alloc.free(f.message);
                },
            }
        }
        self.alloc.free(self.cases);
        self.* = undefined;
    }
};

pub const FixturesError = error{
    UnsupportedExpectKind,
    MissingField,
    InvalidType,
};

pub fn loadCases(alloc: std.mem.Allocator, path: []const u8) !CaseList {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(contents);

    var cases = std.array_list.Managed(Case).init(alloc);
    errdefer {
        for (cases.items) |case| {
            alloc.free(case.name);
            alloc.free(case.sql);
            alloc.free(case.notes);
            switch (case.expect) {
                .success => |s| alloc.free(s.sydraql),
                .failure => |f| {
                    alloc.free(f.sqlstate);
                    alloc.free(f.message);
                },
            }
        }
        cases.deinit();
    }

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return FixturesError.InvalidType;
        const obj = parsed.value.object;

        const name = try dupeField(alloc, obj, "name");
        const sql = try dupeField(alloc, obj, "sql");
        const notes = try dupeOptionalField(alloc, obj, "notes", "");

        const expect_val = obj.get("expect") orelse return FixturesError.MissingField;
        const expect = try parseExpect(alloc, expect_val.*);

        try cases.append(.{ .name = name, .sql = sql, .expect = expect, .notes = notes });
    }

    return CaseList{ .alloc = alloc, .cases = try cases.toOwnedSlice() };
}

fn parseExpect(alloc: std.mem.Allocator, value: std.json.Value) !Expect {
    if (value != .object) return FixturesError.InvalidType;
    const obj = value.object;
    const kind_val = obj.get("kind") orelse return FixturesError.MissingField;
    if (kind_val.* != .string) return FixturesError.InvalidType;
    const kind = kind_val.string;

    if (std.mem.eql(u8, kind, "success")) {
        const sydraql = try dupeField(alloc, obj, "sydraql");
        return Expect{ .success = .{ .sydraql = sydraql } };
    } else if (std.mem.eql(u8, kind, "error")) {
        const sqlstate = try dupeField(alloc, obj, "sqlstate");
        const message = try dupeOptionalField(alloc, obj, "message", "");
        return Expect{ .failure = .{ .sqlstate = sqlstate, .message = message } };
    } else {
        return FixturesError.UnsupportedExpectKind;
    }
}

fn dupeField(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = obj.get(key) orelse return FixturesError.MissingField;
    if (value.* != .string) return FixturesError.InvalidType;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalField(alloc: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, default: []const u8) ![]u8 {
    const maybe = obj.get(key) orelse return alloc.dupe(u8, default);
    if (maybe.* == .string) {
        return alloc.dupe(u8, maybe.string);
    }
    return FixturesError.InvalidType;
}

test "load translator fixtures" {
    const alloc = std.testing.allocator;
    const list = try loadCases(alloc, "tests/translator/cases.jsonl");
    defer list.deinit();
    try std.testing.expect(list.cases.len >= 2);
    const case0 = list.cases[0];
    try std.testing.expectEqualStrings("select-constant", case0.name);
    try std.testing.expect(case0.expect == .success);
    const case1 = list.cases[1];
    try std.testing.expect(case1.expect == .failure);
}
