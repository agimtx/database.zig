const std = @import("std");
const types = @import("types.zig");
const driver = @import("driver.zig");
const registry_mod = @import("registry.zig");

pub const ConnectionError = error{
    DriverNotRegistered,
    ConnectionNotFound,
    ResultSetNotFound,
    CursorNotFound,
    ColumnIndexOutOfBounds,
};

const ConnectionEntry = struct {
    kind: types.DriverKind,
    handle: *driver.ConnectionHandle,
};

const ResultSetEntry = struct {
    kind: types.DriverKind,
    handle: *driver.ResultSetHandle,
};

const CursorEntry = struct {
    kind: types.DriverKind,
    handle: *driver.CursorHandle,
};

pub const ConnectionManager = struct {
    allocator: std.mem.Allocator,
    registry: registry_mod.DriverRegistry,
    connections: std.AutoHashMap(u64, ConnectionEntry),
    result_sets: std.AutoHashMap(u64, ResultSetEntry),
    cursors: std.AutoHashMap(u64, CursorEntry),
    next_connection_id: u64 = 1,
    next_result_set_id: u64 = 1,
    next_cursor_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !ConnectionManager {
        var registry = registry_mod.DriverRegistry.init(allocator);
        try registry.registerBuiltins();

        return .{
            .allocator = allocator,
            .registry = registry,
            .connections = std.AutoHashMap(u64, ConnectionEntry).init(allocator),
            .result_sets = std.AutoHashMap(u64, ResultSetEntry).init(allocator),
            .cursors = std.AutoHashMap(u64, CursorEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        var cursor_iterator = self.cursors.valueIterator();
        while (cursor_iterator.next()) |entry| {
            if (self.registry.resolve(entry.kind)) |spec| {
                spec.close_cursor(self.allocator, entry.handle);
            }
        }

        var result_iterator = self.result_sets.valueIterator();
        while (result_iterator.next()) |entry| {
            if (self.registry.resolve(entry.kind)) |spec| {
                spec.close_result_set(self.allocator, entry.handle);
            }
        }

        var iterator = self.connections.valueIterator();
        while (iterator.next()) |entry| {
            if (self.registry.resolve(entry.kind)) |spec| {
                spec.close(self.allocator, entry.handle);
            }
        }

        self.cursors.deinit();
        self.result_sets.deinit();
        self.connections.deinit();
        self.registry.deinit();
    }

    pub fn registerDriver(self: *ConnectionManager, spec: driver.DriverSpec) !void {
        try self.registry.register(spec);
    }

    pub fn open(self: *ConnectionManager, options: types.ConnectOptions) !*driver.ConnectionHandle {
        const spec = self.registry.resolve(options.driver) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        const connection_id = self.next_connection_id;
        self.next_connection_id += 1;

        const handle = try spec.open(self.allocator, connection_id, options);
        try self.connections.put(connection_id, .{
            .kind = options.driver,
            .handle = handle,
        });

        return handle;
    }

    pub fn close(self: *ConnectionManager, connection_id: u64) !void {
        self.closeCursorsForConnection(connection_id);
        self.closeResultSetsForConnection(connection_id);

        const removed = self.connections.fetchRemove(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };

        const spec = self.registry.resolve(removed.value.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        spec.close(self.allocator, removed.value.handle);
    }

    pub fn execute(
        self: *ConnectionManager,
        connection_id: u64,
        sql: []const u8,
    ) !*driver.ResultSetHandle {
        const entry = self.connections.get(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        const result_set_id = self.next_result_set_id;
        self.next_result_set_id += 1;

        const result_set = try spec.execute(self.allocator, entry.handle, result_set_id, sql);
        try self.result_sets.put(result_set_id, .{
            .kind = entry.kind,
            .handle = result_set,
        });

        return result_set;
    }

    pub fn closeResultSet(self: *ConnectionManager, result_set_id: u64) !void {
        const removed = self.result_sets.fetchRemove(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        const spec = self.registry.resolve(removed.value.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        spec.close_result_set(self.allocator, removed.value.handle);
    }

    pub fn openCursor(
        self: *ConnectionManager,
        connection_id: u64,
        sql: []const u8,
    ) !*driver.CursorHandle {
        const entry = self.connections.get(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        const cursor_id = self.next_cursor_id;
        self.next_cursor_id += 1;

        const cursor = try spec.open_cursor(self.allocator, entry.handle, cursor_id, sql);
        try self.cursors.put(cursor_id, .{
            .kind = entry.kind,
            .handle = cursor,
        });

        return cursor;
    }

    pub fn fetchNext(self: *ConnectionManager, cursor_id: u64) !bool {
        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        return spec.fetch_cursor_next(self.allocator, entry.handle);
    }

    pub fn closeCursor(self: *ConnectionManager, cursor_id: u64) !void {
        const removed = self.cursors.fetchRemove(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };

        const spec = self.registry.resolve(removed.value.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        spec.close_cursor(self.allocator, removed.value.handle);
    }

    pub fn resultSetColumnCount(self: *const ConnectionManager, result_set_id: u64) !usize {
        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.columns.len;
    }

    pub fn resultSetRowCount(self: *const ConnectionManager, result_set_id: u64) !u64 {
        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.row_count;
    }

    pub fn resultSetAffectedRows(self: *const ConnectionManager, result_set_id: u64) !u64 {
        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.affected_rows;
    }

    pub fn resultSetColumn(
        self: *const ConnectionManager,
        result_set_id: u64,
        column_index: usize,
    ) !types.ColumnMetadata {
        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };
        if (column_index >= entry.handle.columns.len) {
            return ConnectionError.ColumnIndexOutOfBounds;
        }

        return entry.handle.columns[column_index];
    }

    pub fn cursorColumnCount(self: *const ConnectionManager, cursor_id: u64) !usize {
        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };

        return entry.handle.columns.len;
    }

    pub fn cursorColumn(
        self: *const ConnectionManager,
        cursor_id: u64,
        column_index: usize,
    ) !types.ColumnMetadata {
        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };
        if (column_index >= entry.handle.columns.len) {
            return ConnectionError.ColumnIndexOutOfBounds;
        }

        return entry.handle.columns[column_index];
    }

    pub fn hasConnection(self: *const ConnectionManager, connection_id: u64) bool {
        return self.connections.contains(connection_id);
    }

    pub fn supportedDrivers(self: *const ConnectionManager) usize {
        return self.registry.count();
    }

    pub fn hasResultSet(self: *const ConnectionManager, result_set_id: u64) bool {
        return self.result_sets.contains(result_set_id);
    }

    pub fn hasCursor(self: *const ConnectionManager, cursor_id: u64) bool {
        return self.cursors.contains(cursor_id);
    }

    fn closeCursorsForConnection(self: *ConnectionManager, connection_id: u64) void {
        while (true) {
            var cursor_id: ?u64 = null;
            var iterator = self.cursors.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.handle.connection_id == connection_id) {
                    cursor_id = entry.key_ptr.*;
                    break;
                }
            }

            const owned_cursor_id = cursor_id orelse break;
            self.closeCursor(owned_cursor_id) catch break;
        }
    }

    fn closeResultSetsForConnection(self: *ConnectionManager, connection_id: u64) void {
        while (true) {
            var result_set_id: ?u64 = null;
            var iterator = self.result_sets.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.handle.connection_id == connection_id) {
                    result_set_id = entry.key_ptr.*;
                    break;
                }
            }

            const owned_result_set_id = result_set_id orelse break;
            self.closeResultSet(owned_result_set_id) catch break;
        }
    }
};

test "builtins can open and close a stub connection" {
    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 1), manager.supportedDrivers());

    const handle = try manager.open(.{
        .driver = .adbc,
        .dsn = "adbc://localhost/analytics",
    });

    try std.testing.expectEqual(@as(u64, 1), handle.id);
    try std.testing.expect(manager.hasConnection(handle.id));

    try manager.close(handle.id);
    try std.testing.expect(!manager.hasConnection(1));
}

test "manager exposes unified execute cursor and metadata contracts" {
    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    const connection = try manager.open(.{
        .driver = .adbc,
        .dsn = "adbc://localhost/analytics",
    });

    const result_set = try manager.execute(connection.id, "select id, value from metrics");
    defer manager.closeResultSet(result_set.id) catch {};

    try std.testing.expect(manager.hasResultSet(result_set.id));
    try std.testing.expectEqual(@as(usize, 2), try manager.resultSetColumnCount(result_set.id));
    try std.testing.expectEqual(@as(u64, 2), result_set.row_count);

    const first_column = try manager.resultSetColumn(result_set.id, 0);
    try std.testing.expectEqualStrings("id", first_column.name);
    try std.testing.expectEqual(types.ColumnType.int64, first_column.column_type);
    try std.testing.expect(!first_column.nullable);

    const cursor = try manager.openCursor(connection.id, "select id, value from metrics");
    defer manager.closeCursor(cursor.id) catch {};

    try std.testing.expect(manager.hasCursor(cursor.id));
    try std.testing.expectEqual(@as(usize, 2), try manager.cursorColumnCount(cursor.id));
    try std.testing.expect(try manager.fetchNext(cursor.id));
    try std.testing.expectEqual(@as(usize, 1), cursor.position);
    try std.testing.expect(try manager.fetchNext(cursor.id));
    try std.testing.expect(!try manager.fetchNext(cursor.id));
}
