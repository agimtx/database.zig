const std = @import("std");
const types = @import("types.zig");
const driver = @import("driver.zig");
const registry_mod = @import("registry.zig");
const adbc_backend = @import("adbc_backend.zig");

pub const ConnectionError = error{
    DriverNotRegistered,
    ConnectionNotFound,
    ResultSetNotFound,
    CursorNotFound,
    RowIndexOutOfBounds,
    ColumnIndexOutOfBounds,
};

pub const AsyncOperationError = error{
    OperationNotFound,
};

pub const AsyncOperationState = enum(u8) {
    pending = 0,
    running = 1,
    succeeded = 2,
    failed = 3,
};

pub const AsyncOperationResult = struct {
    state: AsyncOperationState,
    value: u64 = 0,
    failure: ?anyerror = null,
};

const AsyncOpenPayload = struct {
    driver: types.DriverKind,
    dsn: []u8,
};

const AsyncExecutePayload = struct {
    connection_id: u64,
    sql: []u8,
};

const AsyncCursorPayload = struct {
    connection_id: u64,
    sql: []u8,
};

const AsyncOperationPayload = union(enum) {
    open: AsyncOpenPayload,
    execute: AsyncExecutePayload,
    open_cursor: AsyncCursorPayload,
};

const AsyncOperation = struct {
    id: u64,
    payload: AsyncOperationPayload,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    state: AsyncOperationState = .pending,
    value: u64 = 0,
    failure: ?anyerror = null,
    failure_message: ?[]u8 = null,
    thread: ?std.Thread = null,

    fn begin(self: *AsyncOperation) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .running;
    }

    fn succeed(self: *AsyncOperation, value: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .succeeded;
        self.value = value;
        self.failure = null;
        self.condition.broadcast();
    }

    fn fail(self: *AsyncOperation, err: anyerror, message: ?[]u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .failed;
        self.value = 0;
        self.failure = err;
        self.failure_message = message;
        self.condition.broadcast();
    }

    fn wait(self: *AsyncOperation) AsyncOperationResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.state == .pending or self.state == .running) {
            self.condition.wait(&self.mutex);
        }

        return .{
            .state = self.state,
            .value = self.value,
            .failure = self.failure,
        };
    }

    fn joinThread(self: *AsyncOperation) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn deinit(self: *AsyncOperation, allocator: std.mem.Allocator) void {
        switch (self.payload) {
            .open => |payload| allocator.free(payload.dsn),
            .execute => |payload| allocator.free(payload.sql),
            .open_cursor => |payload| allocator.free(payload.sql),
        }
        if (self.failure_message) |message| {
            allocator.free(message);
        }
    }
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
    operations: std.AutoHashMap(u64, *AsyncOperation),
    last_error_message: ?[]u8 = null,
    state_lock: std.Thread.Mutex = .{},
    next_connection_id: u64 = 1,
    next_result_set_id: u64 = 1,
    next_cursor_id: u64 = 1,
    next_operation_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) !ConnectionManager {
        var registry = registry_mod.DriverRegistry.init(allocator);
        try registry.registerBuiltins();

        return .{
            .allocator = allocator,
            .registry = registry,
            .connections = std.AutoHashMap(u64, ConnectionEntry).init(allocator),
            .result_sets = std.AutoHashMap(u64, ResultSetEntry).init(allocator),
            .cursors = std.AutoHashMap(u64, CursorEntry).init(allocator),
            .operations = std.AutoHashMap(u64, *AsyncOperation).init(allocator),
        };
    }

    pub fn deinit(self: *ConnectionManager) void {
        var operation_iterator = self.operations.valueIterator();
        while (operation_iterator.next()) |entry| {
            entry.*.joinThread();
        }

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

        var async_iterator = self.operations.valueIterator();
        while (async_iterator.next()) |entry| {
            entry.*.deinit(self.allocator);
            self.allocator.destroy(entry.*);
        }

        self.operations.deinit();
        if (self.last_error_message) |message| {
            self.allocator.free(message);
        }
        self.cursors.deinit();
        self.result_sets.deinit();
        self.connections.deinit();
        self.registry.deinit();
    }

    pub fn registerDriver(self: *ConnectionManager, spec: driver.DriverSpec) !void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        try self.registry.register(spec);
    }

    pub fn open(self: *ConnectionManager, options: types.ConnectOptions) !*driver.ConnectionHandle {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        return self.openUnlocked(options);
    }

    pub fn openAsync(self: *ConnectionManager, options: types.ConnectOptions) !u64 {
        const owned_dsn = try self.allocator.dupe(u8, options.dsn);
        errdefer self.allocator.free(owned_dsn);

        const operation = try self.createOperation(.{
            .open = .{
                .driver = options.driver,
                .dsn = owned_dsn,
            },
        });
        errdefer self.destroyOperation(operation);

        try self.startOperation(operation, runOpenOperation);
        return operation.id;
    }

    fn openUnlocked(self: *ConnectionManager, options: types.ConnectOptions) !*driver.ConnectionHandle {
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
        self.state_lock.lock();
        defer self.state_lock.unlock();

        try self.closeUnlocked(connection_id);
    }

    fn closeUnlocked(self: *ConnectionManager, connection_id: u64) !void {
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
        self.state_lock.lock();
        defer self.state_lock.unlock();

        return self.executeUnlocked(connection_id, sql);
    }

    pub fn executeAsync(
        self: *ConnectionManager,
        connection_id: u64,
        sql: []const u8,
    ) !u64 {
        const owned_sql = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(owned_sql);

        const operation = try self.createOperation(.{
            .execute = .{
                .connection_id = connection_id,
                .sql = owned_sql,
            },
        });
        errdefer self.destroyOperation(operation);

        try self.startOperation(operation, runExecuteOperation);
        return operation.id;
    }

    fn executeUnlocked(
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

    pub fn testConnection(self: *ConnectionManager, connection_id: u64) !bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.connections.get(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        return spec.test_connection(self.allocator, entry.handle);
    }

    pub fn getTables(
        self: *ConnectionManager,
        connection_id: u64,
        options: types.GetTablesOptions,
    ) !*driver.ResultSetHandle {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.connections.get(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        const result_set_id = self.next_result_set_id;
        self.next_result_set_id += 1;

        const result_set = try spec.get_tables(self.allocator, entry.handle, result_set_id, options);
        try self.result_sets.put(result_set_id, .{
            .kind = entry.kind,
            .handle = result_set,
        });

        return result_set;
    }

    pub fn getDatabases(self: *ConnectionManager, connection_id: u64) !*driver.ResultSetHandle {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.connections.get(connection_id) orelse {
            return ConnectionError.ConnectionNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        const result_set_id = self.next_result_set_id;
        self.next_result_set_id += 1;

        const result_set = try spec.get_databases(self.allocator, entry.handle, result_set_id);
        try self.result_sets.put(result_set_id, .{
            .kind = entry.kind,
            .handle = result_set,
        });

        return result_set;
    }

    pub fn getDatabase(self: *ConnectionManager, connection_id: u64) !*driver.ResultSetHandle {
        return self.getDatabases(connection_id);
    }

    pub fn closeResultSet(self: *ConnectionManager, result_set_id: u64) !void {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        try self.closeResultSetUnlocked(result_set_id);
    }

    fn closeResultSetUnlocked(self: *ConnectionManager, result_set_id: u64) !void {
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
        self.state_lock.lock();
        defer self.state_lock.unlock();

        return self.openCursorUnlocked(connection_id, sql);
    }

    pub fn openCursorAsync(
        self: *ConnectionManager,
        connection_id: u64,
        sql: []const u8,
    ) !u64 {
        const owned_sql = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(owned_sql);

        const operation = try self.createOperation(.{
            .open_cursor = .{
                .connection_id = connection_id,
                .sql = owned_sql,
            },
        });
        errdefer self.destroyOperation(operation);

        try self.startOperation(operation, runOpenCursorOperation);
        return operation.id;
    }

    fn openCursorUnlocked(
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

    pub fn awaitOperation(self: *ConnectionManager, operation_id: u64) !AsyncOperationResult {
        self.state_lock.lock();
        const operation = self.operations.get(operation_id) orelse {
            self.state_lock.unlock();
            return AsyncOperationError.OperationNotFound;
        };
        self.state_lock.unlock();

        const result = operation.wait();
        operation.joinThread();

        self.state_lock.lock();
        _ = self.operations.remove(operation_id);
        self.state_lock.unlock();

        if (operation.failure_message) |message| {
            try self.setLastErrorOwned(message);
            operation.failure_message = null;
        }

        operation.deinit(self.allocator);
        self.allocator.destroy(operation);
        return result;
    }

    pub fn clearLastError(self: *ConnectionManager) void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.clearLastErrorUnlocked();
    }

    pub fn setLastErrorCopy(self: *ConnectionManager, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned);
        try self.setLastErrorOwned(owned);
    }

    pub fn setLastErrorOwned(self: *ConnectionManager, message: []u8) !void {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        self.clearLastErrorUnlocked();
        self.last_error_message = message;
    }

    pub fn lastErrorMessage(self: *ConnectionManager) ?[]const u8 {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.last_error_message;
    }

    fn clearLastErrorUnlocked(self: *ConnectionManager) void {
        if (self.last_error_message) |message| {
            self.allocator.free(message);
            self.last_error_message = null;
        }
    }

    pub fn fetchNext(self: *ConnectionManager, cursor_id: u64) !bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };
        const spec = self.registry.resolve(entry.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        return spec.fetch_cursor_next(self.allocator, entry.handle);
    }

    pub fn closeCursor(self: *ConnectionManager, cursor_id: u64) !void {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        try self.closeCursorUnlocked(cursor_id);
    }

    fn closeCursorUnlocked(self: *ConnectionManager, cursor_id: u64) !void {
        const removed = self.cursors.fetchRemove(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };

        const spec = self.registry.resolve(removed.value.kind) orelse {
            return ConnectionError.DriverNotRegistered;
        };

        spec.close_cursor(self.allocator, removed.value.handle);
    }

    pub fn resultSetColumnCount(self: *ConnectionManager, result_set_id: u64) !usize {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.columns.len;
    }

    pub fn resultSetRowCount(self: *ConnectionManager, result_set_id: u64) !u64 {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.row_count;
    }

    pub fn resultSetAffectedRows(self: *ConnectionManager, result_set_id: u64) !u64 {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };

        return entry.handle.affected_rows;
    }

    pub fn resultSetColumn(
        self: *ConnectionManager,
        result_set_id: u64,
        column_index: usize,
    ) !types.ColumnMetadata {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };
        if (column_index >= entry.handle.columns.len) {
            return ConnectionError.ColumnIndexOutOfBounds;
        }

        return entry.handle.columns[column_index];
    }

    pub fn resultSetCell(
        self: *ConnectionManager,
        result_set_id: u64,
        row_index: usize,
        column_index: usize,
    ) !types.ResultCell {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.result_sets.get(result_set_id) orelse {
            return ConnectionError.ResultSetNotFound;
        };
        if (row_index >= entry.handle.rows.len) {
            return ConnectionError.RowIndexOutOfBounds;
        }

        const row = entry.handle.rows[row_index];
        if (column_index >= row.values.len) {
            return ConnectionError.ColumnIndexOutOfBounds;
        }

        return row.values[column_index];
    }

    pub fn cursorColumnCount(self: *ConnectionManager, cursor_id: u64) !usize {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };

        return entry.handle.columns.len;
    }

    pub fn cursorColumn(
        self: *ConnectionManager,
        cursor_id: u64,
        column_index: usize,
    ) !types.ColumnMetadata {
        self.state_lock.lock();
        defer self.state_lock.unlock();

        const entry = self.cursors.get(cursor_id) orelse {
            return ConnectionError.CursorNotFound;
        };
        if (column_index >= entry.handle.columns.len) {
            return ConnectionError.ColumnIndexOutOfBounds;
        }

        return entry.handle.columns[column_index];
    }

    pub fn hasConnection(self: *ConnectionManager, connection_id: u64) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.connections.contains(connection_id);
    }

    pub fn supportedDrivers(self: *ConnectionManager) usize {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.registry.count();
    }

    pub fn hasResultSet(self: *ConnectionManager, result_set_id: u64) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.result_sets.contains(result_set_id);
    }

    pub fn hasCursor(self: *ConnectionManager, cursor_id: u64) bool {
        self.state_lock.lock();
        defer self.state_lock.unlock();
        return self.cursors.contains(cursor_id);
    }

    fn createOperation(self: *ConnectionManager, payload: AsyncOperationPayload) !*AsyncOperation {
        const operation = try self.allocator.create(AsyncOperation);
        errdefer self.allocator.destroy(operation);

        operation.* = .{
            .id = 0,
            .payload = payload,
        };
        errdefer operation.deinit(self.allocator);

        self.state_lock.lock();
        defer self.state_lock.unlock();

        operation.id = self.next_operation_id;
        self.next_operation_id += 1;
        try self.operations.put(operation.id, operation);
        return operation;
    }

    fn destroyOperation(self: *ConnectionManager, operation: *AsyncOperation) void {
        self.state_lock.lock();
        _ = self.operations.remove(operation.id);
        self.state_lock.unlock();

        operation.deinit(self.allocator);
        self.allocator.destroy(operation);
    }

    fn startOperation(
        self: *ConnectionManager,
        operation: *AsyncOperation,
        comptime runFn: fn (*ConnectionManager, *AsyncOperation) void,
    ) !void {
        operation.thread = try std.Thread.spawn(.{}, runFn, .{ self, operation });
    }

    fn runOpenOperation(self: *ConnectionManager, operation: *AsyncOperation) void {
        operation.begin();
        adbc_backend.clearLastDriverErrorMessage();
        const payload = operation.payload.open;
        const handle = self.open(.{
            .driver = payload.driver,
            .dsn = payload.dsn,
        }) catch |err| {
            operation.fail(err, adbc_backend.takeLastDriverErrorMessage(self.allocator));
            return;
        };
        operation.succeed(handle.id);
    }

    fn runExecuteOperation(self: *ConnectionManager, operation: *AsyncOperation) void {
        operation.begin();
        adbc_backend.clearLastDriverErrorMessage();
        const payload = operation.payload.execute;
        const result_set = self.execute(payload.connection_id, payload.sql) catch |err| {
            operation.fail(err, adbc_backend.takeLastDriverErrorMessage(self.allocator));
            return;
        };
        operation.succeed(result_set.id);
    }

    fn runOpenCursorOperation(self: *ConnectionManager, operation: *AsyncOperation) void {
        operation.begin();
        adbc_backend.clearLastDriverErrorMessage();
        const payload = operation.payload.open_cursor;
        const cursor = self.openCursor(payload.connection_id, payload.sql) catch |err| {
            operation.fail(err, adbc_backend.takeLastDriverErrorMessage(self.allocator));
            return;
        };
        operation.succeed(cursor.id);
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
            self.closeCursorUnlocked(owned_cursor_id) catch break;
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
            self.closeResultSetUnlocked(owned_result_set_id) catch break;
        }
    }
};

test "builtins can open and close a real adbc connection" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 1), manager.supportedDrivers());

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);

    const handle = try manager.open(.{
        .driver = .adbc,
        .dsn = dsn,
    });

    try std.testing.expectEqual(@as(u64, 1), handle.id);
    try std.testing.expect(manager.hasConnection(handle.id));

    try manager.close(handle.id);
    try std.testing.expect(!manager.hasConnection(1));
}

test "manager exposes unified execute cursor and metadata contracts" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);

    const connection = try manager.open(.{
        .driver = .adbc,
        .dsn = dsn,
    });

    const result_set = try manager.execute(
        connection.id,
        "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value",
    );
    defer manager.closeResultSet(result_set.id) catch {};

    try std.testing.expect(manager.hasResultSet(result_set.id));
    try std.testing.expectEqual(@as(usize, 2), try manager.resultSetColumnCount(result_set.id));
    try std.testing.expectEqual(@as(u64, 2), result_set.row_count);

    const first_value = try manager.resultSetCell(result_set.id, 0, 1);
    try std.testing.expectEqualStrings("alpha", first_value.text);
    try std.testing.expect(!first_value.is_null);

    const first_column = try manager.resultSetColumn(result_set.id, 0);
    try std.testing.expectEqualStrings("id", first_column.name);
    try std.testing.expectEqual(types.ColumnType.int64, first_column.column_type);

    const cursor = try manager.openCursor(
        connection.id,
        "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value",
    );
    defer manager.closeCursor(cursor.id) catch {};

    try std.testing.expect(manager.hasCursor(cursor.id));
    try std.testing.expectEqual(@as(usize, 2), try manager.cursorColumnCount(cursor.id));
    try std.testing.expect(try manager.fetchNext(cursor.id));
    try std.testing.expectEqual(@as(usize, 1), cursor.position);
    try std.testing.expect(try manager.fetchNext(cursor.id));
    try std.testing.expect(!try manager.fetchNext(cursor.id));
}

test "manager exposes test and metadata discovery contracts" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);

    const connection = try manager.open(.{
        .driver = .adbc,
        .dsn = dsn,
    });

    try std.testing.expect(try manager.testConnection(connection.id));

    const tables = try manager.getTables(connection.id, .{ .database = "main" });
    defer manager.closeResultSet(tables.id) catch {};

    try std.testing.expect(try manager.resultSetColumnCount(tables.id) >= 6);
    try std.testing.expect((try manager.resultSetRowCount(tables.id)) >= 1);

    const database_name = try manager.resultSetCell(tables.id, 0, 1);
    try std.testing.expectEqualStrings("main", database_name.text);

    const namespace_kind = try manager.resultSetColumn(tables.id, 4);
    try std.testing.expectEqualStrings("namespace_kind", namespace_kind.name);

    const qualified_name = try manager.resultSetColumn(tables.id, 5);
    try std.testing.expectEqualStrings("qualified_name", qualified_name.name);

    const qualified_name_value = try manager.resultSetCell(tables.id, 0, 5);
    try std.testing.expect(qualified_name_value.text.len != 0);

    const databases = try manager.getDatabases(connection.id);
    defer manager.closeResultSet(databases.id) catch {};

    try std.testing.expect((try manager.resultSetRowCount(databases.id)) >= 1);
    const listed_database = try manager.resultSetCell(databases.id, 0, 0);
    try std.testing.expectEqualStrings("main", listed_database.text);
}

test "manager async operations return handles through await" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    var manager = try ConnectionManager.init(std.testing.allocator);
    defer manager.deinit();

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);

    const open_operation = try manager.openAsync(.{
        .driver = .adbc,
        .dsn = dsn,
    });
    const open_result = try manager.awaitOperation(open_operation);
    try std.testing.expectEqual(AsyncOperationState.succeeded, open_result.state);
    const connection_id = open_result.value;

    const execute_operation = try manager.executeAsync(
        connection_id,
        "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value",
    );
    const execute_result = try manager.awaitOperation(execute_operation);
    try std.testing.expectEqual(AsyncOperationState.succeeded, execute_result.state);
    defer manager.closeResultSet(execute_result.value) catch {};
    try std.testing.expectEqual(@as(u64, 2), try manager.resultSetRowCount(execute_result.value));

    const cursor_operation = try manager.openCursorAsync(
        connection_id,
        "select 1 as id, 'alpha' as value union all select 2 as id, 'beta' as value",
    );
    const cursor_result = try manager.awaitOperation(cursor_operation);
    try std.testing.expectEqual(AsyncOperationState.succeeded, cursor_result.state);
    defer manager.closeCursor(cursor_result.value) catch {};
    try std.testing.expect(try manager.fetchNext(cursor_result.value));

    try manager.close(connection_id);
}
