const std = @import("std");
const types = @import("types.zig");

pub const ConnectionState = enum(u8) {
    initializing,
    open,
    closed,
};

pub const ConnectionHandle = struct {
    id: u64,
    driver: types.DriverKind,
    opaque_handle: usize = 0,
    state: ConnectionState = .initializing,
};

pub const ResultSetHandle = struct {
    id: u64,
    connection_id: u64,
    columns: []const types.ColumnMetadata,
    row_count: u64 = 0,
    affected_rows: u64 = 0,
    opaque_handle: usize = 0,
};

pub const CursorHandle = struct {
    id: u64,
    connection_id: u64,
    columns: []const types.ColumnMetadata,
    total_rows: usize = 0,
    position: usize = 0,
    opaque_handle: usize = 0,
};

pub const OpenConnectionFn = *const fn (
    allocator: std.mem.Allocator,
    connection_id: u64,
    options: types.ConnectOptions,
) anyerror!*ConnectionHandle;

pub const CloseConnectionFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *ConnectionHandle,
) void;

pub const ExecuteSqlFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *ConnectionHandle,
    result_set_id: u64,
    sql: []const u8,
) anyerror!*ResultSetHandle;

pub const CloseResultSetFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *ResultSetHandle,
) void;

pub const OpenCursorFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *ConnectionHandle,
    cursor_id: u64,
    sql: []const u8,
) anyerror!*CursorHandle;

pub const FetchCursorNextFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *CursorHandle,
) anyerror!bool;

pub const CloseCursorFn = *const fn (
    allocator: std.mem.Allocator,
    handle: *CursorHandle,
) void;

pub const DriverSpec = struct {
    kind: types.DriverKind,
    name: []const u8,
    language: types.DriverLanguage = .shared_library,
    open: OpenConnectionFn,
    close: CloseConnectionFn,
    execute: ExecuteSqlFn,
    close_result_set: CloseResultSetFn,
    open_cursor: OpenCursorFn,
    fetch_cursor_next: FetchCursorNextFn,
    close_cursor: CloseCursorFn,
};

const stub_columns = [_]types.ColumnMetadata{
    .{
        .name = "id",
        .column_type = .int64,
        .nullable = false,
    },
    .{
        .name = "value",
        .column_type = .text,
        .nullable = true,
    },
};

pub fn stubOpen(
    allocator: std.mem.Allocator,
    connection_id: u64,
    options: types.ConnectOptions,
) !*ConnectionHandle {
    const handle = try allocator.create(ConnectionHandle);
    handle.* = .{
        .id = connection_id,
        .driver = options.driver,
        .state = .open,
    };
    return handle;
}

pub fn stubClose(allocator: std.mem.Allocator, handle: *ConnectionHandle) void {
    handle.state = .closed;
    allocator.destroy(handle);
}

pub fn stubExecute(
    allocator: std.mem.Allocator,
    handle: *ConnectionHandle,
    result_set_id: u64,
    sql: []const u8,
) !*ResultSetHandle {
    _ = sql;

    const result_set = try allocator.create(ResultSetHandle);
    result_set.* = .{
        .id = result_set_id,
        .connection_id = handle.id,
        .columns = stub_columns[0..],
        .row_count = 2,
        .affected_rows = 2,
    };
    return result_set;
}

pub fn stubCloseResultSet(allocator: std.mem.Allocator, handle: *ResultSetHandle) void {
    allocator.destroy(handle);
}

pub fn stubOpenCursor(
    allocator: std.mem.Allocator,
    handle: *ConnectionHandle,
    cursor_id: u64,
    sql: []const u8,
) !*CursorHandle {
    _ = sql;

    const cursor = try allocator.create(CursorHandle);
    cursor.* = .{
        .id = cursor_id,
        .connection_id = handle.id,
        .columns = stub_columns[0..],
        .total_rows = 2,
    };
    return cursor;
}

pub fn stubFetchCursorNext(allocator: std.mem.Allocator, handle: *CursorHandle) !bool {
    _ = allocator;

    if (handle.position >= handle.total_rows) {
        return false;
    }

    handle.position += 1;
    return true;
}

pub fn stubCloseCursor(allocator: std.mem.Allocator, handle: *CursorHandle) void {
    allocator.destroy(handle);
}
