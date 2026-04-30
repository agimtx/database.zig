const std = @import("std");
const root = @import("../root.zig");

pub const module_anchor = true;

pub const dbz_ok: i32 = 0;
pub const dbz_invalid_argument: i32 = 1;
pub const dbz_driver_not_registered: i32 = 2;
pub const dbz_connection_not_found: i32 = 3;
pub const dbz_result_set_not_found: i32 = 4;
pub const dbz_cursor_not_found: i32 = 5;
pub const dbz_column_index_out_of_bounds: i32 = 6;
pub const dbz_row_index_out_of_bounds: i32 = 7;
pub const dbz_operation_not_found: i32 = 8;
pub const dbz_internal_error: i32 = 255;

pub const DbzOperationState = enum(u8) {
    pending = 0,
    running = 1,
    succeeded = 2,
    failed = 3,
};

pub const DbzColumnMetadata = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    column_type: i32,
    nullable: u8,
};

pub const DbzResultCell = extern struct {
    text_ptr: [*]const u8,
    text_len: usize,
    is_null: u8,
};

pub const DbzOperationResult = extern struct {
    state: u8,
    status: i32,
    value: u64,
};

const ffi_allocator = std.heap.page_allocator;

fn castManager(raw_manager: ?*anyopaque) ?*root.ConnectionManager {
    const opaque_ptr = raw_manager orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

fn driverFromInt(value: i32) ?root.DriverKind {
    return switch (value) {
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10 => .adbc,
        else => null,
    };
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.InvalidArgument => dbz_invalid_argument,
        error.DriverNotRegistered => dbz_driver_not_registered,
        error.ConnectionNotFound => dbz_connection_not_found,
        error.ResultSetNotFound => dbz_result_set_not_found,
        error.CursorNotFound => dbz_cursor_not_found,
        error.RowIndexOutOfBounds => dbz_row_index_out_of_bounds,
        error.ColumnIndexOutOfBounds => dbz_column_index_out_of_bounds,
        error.OperationNotFound => dbz_operation_not_found,
        else => dbz_internal_error,
    };
}

fn fillColumnMetadata(out_metadata: *DbzColumnMetadata, metadata: root.ColumnMetadata) void {
    out_metadata.* = .{
        .name_ptr = metadata.name.ptr,
        .name_len = metadata.name.len,
        .column_type = @intFromEnum(metadata.column_type),
        .nullable = if (metadata.nullable) 1 else 0,
    };
}

fn fillResultCell(out_cell: *DbzResultCell, cell: root.ResultCell) void {
    out_cell.* = .{
        .text_ptr = cell.text.ptr,
        .text_len = cell.text.len,
        .is_null = if (cell.is_null) 1 else 0,
    };
}

pub fn dbz_manager_create() ?*anyopaque {
    const manager = ffi_allocator.create(root.ConnectionManager) catch return null;
    manager.* = root.ConnectionManager.init(ffi_allocator) catch {
        ffi_allocator.destroy(manager);
        return null;
    };
    return @ptrCast(manager);
}

pub fn dbz_manager_destroy(raw_manager: ?*anyopaque) void {
    const manager = castManager(raw_manager) orelse return;
    manager.deinit();
    ffi_allocator.destroy(manager);
}

pub fn dbz_connection_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const kind = driverFromInt(driver_kind) orelse return 0;
    const dsn_value = dsn orelse return 0;

    const handle = manager.open(.{
        .driver = kind,
        .dsn = std.mem.span(dsn_value),
    }) catch return 0;

    return handle.id;
}

pub fn dbz_connection_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const kind = driverFromInt(driver_kind) orelse return 0;
    const dsn_value = dsn orelse return 0;

    return manager.openAsync(.{
        .driver = kind,
        .dsn = std.mem.span(dsn_value),
    }) catch return 0;
}

pub fn dbz_manager_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return dbz_connection_open(raw_manager, driver_kind, dsn);
}

pub fn dbz_manager_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return dbz_connection_open_async(raw_manager, driver_kind, dsn);
}

pub fn dbz_connection_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.close(connection_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_manager_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    return dbz_connection_close(raw_manager, connection_id);
}

pub fn dbz_connection_execute(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    const result_set = manager.execute(connection_id, std.mem.span(sql_value)) catch return 0;
    return result_set.id;
}

pub fn dbz_connection_execute_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    return manager.executeAsync(connection_id, std.mem.span(sql_value)) catch return 0;
}

pub fn dbz_connection_test(raw_manager: ?*anyopaque, connection_id: u64, out_ok: ?*u8) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const ok = out_ok orelse return dbz_invalid_argument;

    ok.* = if (manager.testConnection(connection_id) catch |err| {
        return mapError(err);
    }) 1 else 0;

    return dbz_ok;
}

pub fn dbz_connection_get_tables(
    raw_manager: ?*anyopaque,
    connection_id: u64,
    catalog: ?[*:0]const u8,
    database: ?[*:0]const u8,
) u64 {
    const manager = castManager(raw_manager) orelse return 0;

    const result_set = manager.getTables(connection_id, .{
        .catalog = if (catalog) |value| std.mem.span(value) else null,
        .database = if (database) |value| std.mem.span(value) else null,
    }) catch return 0;
    return result_set.id;
}

pub fn dbz_connection_get_databases(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    const manager = castManager(raw_manager) orelse return 0;

    const result_set = manager.getDatabases(connection_id) catch return 0;
    return result_set.id;
}

pub fn dbz_connection_get_database(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    return dbz_connection_get_databases(raw_manager, connection_id);
}

pub fn dbz_result_set_close(raw_manager: ?*anyopaque, result_set_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.closeResultSet(result_set_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_result_set_row_count(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_row_count: ?*u64,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const row_count = out_row_count orelse return dbz_invalid_argument;

    row_count.* = manager.resultSetRowCount(result_set_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_result_set_affected_rows(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_affected_rows: ?*u64,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const affected_rows = out_affected_rows orelse return dbz_invalid_argument;

    affected_rows.* = manager.resultSetAffectedRows(result_set_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_result_set_column_count(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_column_count: ?*usize,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const column_count = out_column_count orelse return dbz_invalid_argument;

    column_count.* = manager.resultSetColumnCount(result_set_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_result_set_column_metadata(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    column_index: usize,
    out_metadata: ?*DbzColumnMetadata,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const metadata_out = out_metadata orelse return dbz_invalid_argument;

    const metadata = manager.resultSetColumn(result_set_id, column_index) catch |err| {
        return mapError(err);
    };
    fillColumnMetadata(metadata_out, metadata);

    return dbz_ok;
}

pub fn dbz_result_set_value(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    row_index: usize,
    column_index: usize,
    out_cell: ?*DbzResultCell,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const cell_out = out_cell orelse return dbz_invalid_argument;

    const cell = manager.resultSetCell(result_set_id, row_index, column_index) catch |err| {
        return mapError(err);
    };
    fillResultCell(cell_out, cell);

    return dbz_ok;
}

pub fn dbz_cursor_open(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    const cursor = manager.openCursor(connection_id, std.mem.span(sql_value)) catch return 0;
    return cursor.id;
}

pub fn dbz_cursor_open_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    return manager.openCursorAsync(connection_id, std.mem.span(sql_value)) catch return 0;
}

pub fn dbz_operation_await(
    raw_manager: ?*anyopaque,
    operation_id: u64,
    out_result: ?*DbzOperationResult,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const result_out = out_result orelse return dbz_invalid_argument;

    const result = manager.awaitOperation(operation_id) catch |err| {
        return mapError(err);
    };

    result_out.* = .{
        .state = @intFromEnum(switch (result.state) {
            .pending => DbzOperationState.pending,
            .running => DbzOperationState.running,
            .succeeded => DbzOperationState.succeeded,
            .failed => DbzOperationState.failed,
        }),
        .status = if (result.failure) |failure| mapError(failure) else dbz_ok,
        .value = result.value,
    };

    return dbz_ok;
}

pub fn dbz_cursor_next(raw_manager: ?*anyopaque, cursor_id: u64, out_has_row: ?*u8) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const has_row = out_has_row orelse return dbz_invalid_argument;

    has_row.* = if (manager.fetchNext(cursor_id) catch |err| {
        return mapError(err);
    }) 1 else 0;

    return dbz_ok;
}

pub fn dbz_cursor_close(raw_manager: ?*anyopaque, cursor_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.closeCursor(cursor_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_cursor_column_count(
    raw_manager: ?*anyopaque,
    cursor_id: u64,
    out_column_count: ?*usize,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const column_count = out_column_count orelse return dbz_invalid_argument;

    column_count.* = manager.cursorColumnCount(cursor_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

pub fn dbz_cursor_column_metadata(
    raw_manager: ?*anyopaque,
    cursor_id: u64,
    column_index: usize,
    out_metadata: ?*DbzColumnMetadata,
) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const metadata_out = out_metadata orelse return dbz_invalid_argument;

    const metadata = manager.cursorColumn(cursor_id, column_index) catch |err| {
        return mapError(err);
    };
    fillColumnMetadata(metadata_out, metadata);

    return dbz_ok;
}
