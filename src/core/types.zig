const std = @import("std");

pub const DriverKind = enum(u8) {
    adbc,
    custom,
};

pub const DriverLanguage = enum(u8) {
    shared_library,
    native_zig,
    external_process,
};

pub const ColumnType = enum(i32) {
    unknown = 0,
    boolean = 1,
    int64 = 2,
    float64 = 3,
    text = 4,
    binary = 5,
    decimal = 6,
    timestamp = 7,
    json = 8,
    date = 9,
    time = 10,
    interval = 11,
    uuid = 12,
    array = 13,
    map = 14,
    struct_ = 15,
    int8 = 16,
    uint8 = 17,
    int16 = 18,
    uint16 = 19,
    int32 = 20,
    uint32 = 21,
    uint64 = 22,
    float16 = 23,
    float32 = 24,
    duration = 25,
};

pub const ColumnMetadata = struct {
    name: []const u8,
    raw_type: ?[]const u8 = null,
    column_type: ColumnType = .unknown,
    nullable: bool = true,
};

pub const ResultCell = struct {
    text: []const u8,
    is_null: bool = false,
};

pub const ResultRow = struct {
    values: []const ResultCell,
};

pub const QualifiedNamePartRole = enum(u8) {
    catalog,
    database,
    schema,
    dataset,
    namespace,
    object,
};

pub const QualifiedNamePart = struct {
    role: QualifiedNamePartRole,
    value: []const u8,
};

pub const QualifiedName = struct {
    parts: []const QualifiedNamePart,

    pub fn format(self: QualifiedName, allocator: std.mem.Allocator, separator: []const u8) ![]u8 {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        var wrote_part = false;
        for (self.parts) |part| {
            if (part.value.len == 0) continue;

            if (wrote_part) {
                try builder.appendSlice(allocator, separator);
            }
            try builder.appendSlice(allocator, part.value);
            wrote_part = true;
        }

        return builder.toOwnedSlice(allocator);
    }
};

pub const GetTablesOptions = struct {
    catalog: ?[]const u8 = null,
    database: ?[]const u8 = null,
};

pub const NamespaceAccessOptions = struct {
    catalog: ?[]const u8 = null,
    database: ?[]const u8 = null,
};

pub const NamespaceAccess = struct {
    can_get_schema: bool = false,
    has_catalog_access: bool = false,
    has_namespace_access: bool = false,
    namespace_role: QualifiedNamePartRole = .database,
    part_count: usize = 0,
    parts: [2]QualifiedNamePart = .{
        .{ .role = .catalog, .value = "" },
        .{ .role = .database, .value = "" },
    },

    pub fn qualifiedName(self: *const NamespaceAccess) QualifiedName {
        return .{ .parts = self.parts[0..self.part_count] };
    }
};

pub const ConnectOptions = struct {
    driver: DriverKind,
    dsn: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    database: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    warehouse: ?[]const u8 = null,
    role: ?[]const u8 = null,
    flags: u32 = 0,
};

test "qualified name preserves ordered non-empty parts" {
    const qualified_name = QualifiedName{
        .parts = &[_]QualifiedNamePart{
            .{ .role = .catalog, .value = "analytics" },
            .{ .role = .schema, .value = "public" },
            .{ .role = .object, .value = "events" },
        },
    };

    const formatted = try qualified_name.format(std.testing.allocator, ".");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("analytics.public.events", formatted);
}

test "qualified name skips empty parts" {
    const qualified_name = QualifiedName{
        .parts = &[_]QualifiedNamePart{
            .{ .role = .catalog, .value = "" },
            .{ .role = .database, .value = "main" },
            .{ .role = .object, .value = "records" },
        },
    };

    const formatted = try qualified_name.format(std.testing.allocator, ".");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("main.records", formatted);
}

test "namespace access exposes requested qualified name parts" {
    const access = NamespaceAccess{
        .can_get_schema = true,
        .has_catalog_access = true,
        .has_namespace_access = true,
        .namespace_role = .schema,
        .part_count = 2,
        .parts = .{
            .{ .role = .catalog, .value = "analytics" },
            .{ .role = .schema, .value = "public" },
        },
    };

    const formatted = try access.qualifiedName().format(std.testing.allocator, ".");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("analytics.public", formatted);
}
