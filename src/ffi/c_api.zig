const std = @import("std");
const root = @import("../root.zig");
const adbc_backend = @import("../core/adbc_backend.zig");

pub const module_anchor = true;

pub const aq_ok: i32 = 0;
pub const aq_invalid_argument: i32 = 1;
pub const aq_driver_not_registered: i32 = 2;
pub const aq_connection_not_found: i32 = 3;
pub const aq_result_set_not_found: i32 = 4;
pub const aq_cursor_not_found: i32 = 5;
pub const aq_column_index_out_of_bounds: i32 = 6;
pub const aq_row_index_out_of_bounds: i32 = 7;
pub const aq_operation_not_found: i32 = 8;
pub const aq_internal_error: i32 = 255;

pub const AqOperationState = enum(u8) {
    pending = 0,
    running = 1,
    succeeded = 2,
    failed = 3,
};

pub const AqColumnMetadata = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    column_type: i32,
    nullable: u8,
};

pub const AqResultCell = extern struct {
    text_ptr: [*]const u8,
    text_len: usize,
    is_null: u8,
};

pub const AqOperationResult = extern struct {
    state: u8,
    status: i32,
    value: u64,
};

pub const AqErrorMessage = extern struct {
    message_ptr: ?[*]const u8,
    message_len: usize,
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
        error.InvalidArgument => aq_invalid_argument,
        error.DriverNotRegistered => aq_driver_not_registered,
        error.ConnectionNotFound => aq_connection_not_found,
        error.ResultSetNotFound => aq_result_set_not_found,
        error.CursorNotFound => aq_cursor_not_found,
        error.RowIndexOutOfBounds => aq_row_index_out_of_bounds,
        error.ColumnIndexOutOfBounds => aq_column_index_out_of_bounds,
        error.OperationNotFound => aq_operation_not_found,
        else => aq_internal_error,
    };
}

fn fillColumnMetadata(out_metadata: *AqColumnMetadata, metadata: root.ColumnMetadata) void {
    out_metadata.* = .{
        .name_ptr = metadata.name.ptr,
        .name_len = metadata.name.len,
        .column_type = @intFromEnum(metadata.column_type),
        .nullable = if (metadata.nullable) 1 else 0,
    };
}

fn fillResultCell(out_cell: *AqResultCell, cell: root.ResultCell) void {
    out_cell.* = .{
        .text_ptr = cell.text.ptr,
        .text_len = cell.text.len,
        .is_null = if (cell.is_null) 1 else 0,
    };
}

fn defaultStatusMessage(status: i32) []const u8 {
    return switch (status) {
        aq_invalid_argument => "invalid argument",
        aq_driver_not_registered => "driver not registered",
        aq_connection_not_found => "connection not found",
        aq_result_set_not_found => "result set not found",
        aq_cursor_not_found => "cursor not found",
        aq_column_index_out_of_bounds => "column index out of bounds",
        aq_row_index_out_of_bounds => "row index out of bounds",
        aq_operation_not_found => "operation not found",
        else => "internal error",
    };
}

fn clearManagerError(manager: ?*root.ConnectionManager) void {
    if (manager) |typed_manager| {
        typed_manager.clearLastError();
    }
}

fn setManagerError(manager: *root.ConnectionManager, err: anyerror) void {
    if (adbc_backend.takeLastDriverErrorMessage(ffi_allocator)) |message| {
        manager.setLastErrorOwned(message) catch {
            ffi_allocator.free(message);
        };
        return;
    }

    manager.setLastErrorCopy(defaultStatusMessage(mapError(err))) catch {};
}

pub fn aq_manager_create() ?*anyopaque {
    const manager = ffi_allocator.create(root.ConnectionManager) catch return null;
    manager.* = root.ConnectionManager.init(ffi_allocator) catch {
        ffi_allocator.destroy(manager);
        return null;
    };
    return @ptrCast(manager);
}

pub fn aq_manager_destroy(raw_manager: ?*anyopaque) void {
    const manager = castManager(raw_manager) orelse return;
    manager.deinit();
    ffi_allocator.destroy(manager);
}

pub fn aq_connection_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const kind = driverFromInt(driver_kind) orelse return 0;
    const dsn_value = dsn orelse return 0;
    adbc_backend.clearLastDriverErrorMessage();

    const handle = manager.open(.{
        .driver = kind,
        .dsn = std.mem.span(dsn_value),
    }) catch |err| {
        setManagerError(manager, err);
        return 0;
    };

    return handle.id;
}

pub fn aq_connection_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const kind = driverFromInt(driver_kind) orelse return 0;
    const dsn_value = dsn orelse return 0;

    return manager.openAsync(.{
        .driver = kind,
        .dsn = std.mem.span(dsn_value),
    }) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
}

pub fn aq_manager_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return aq_connection_open(raw_manager, driver_kind, dsn);
}

pub fn aq_manager_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return aq_connection_open_async(raw_manager, driver_kind, dsn);
}

pub fn aq_connection_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);

    manager.close(connection_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_manager_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    return aq_connection_close(raw_manager, connection_id);
}

pub fn aq_connection_execute(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const sql_value = sql orelse return 0;
    adbc_backend.clearLastDriverErrorMessage();

    const result_set = manager.execute(connection_id, std.mem.span(sql_value)) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
    return result_set.id;
}

pub fn aq_connection_execute_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const sql_value = sql orelse return 0;

    return manager.executeAsync(connection_id, std.mem.span(sql_value)) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
}

pub fn aq_connection_test(raw_manager: ?*anyopaque, connection_id: u64, out_ok: ?*u8) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const ok = out_ok orelse return aq_invalid_argument;

    ok.* = if (manager.testConnection(connection_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    }) 1 else 0;

    return aq_ok;
}

pub fn aq_connection_get_tables(
    raw_manager: ?*anyopaque,
    connection_id: u64,
    catalog: ?[*:0]const u8,
    database: ?[*:0]const u8,
) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);

    const result_set = manager.getTables(connection_id, .{
        .catalog = if (catalog) |value| std.mem.span(value) else null,
        .database = if (database) |value| std.mem.span(value) else null,
    }) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
    return result_set.id;
}

pub fn aq_connection_get_databases(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);

    const result_set = manager.getDatabases(connection_id) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
    return result_set.id;
}

pub fn aq_connection_get_database(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    return aq_connection_get_databases(raw_manager, connection_id);
}

pub fn aq_result_set_close(raw_manager: ?*anyopaque, result_set_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);

    manager.closeResultSet(result_set_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_result_set_row_count(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_row_count: ?*u64,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const row_count = out_row_count orelse return aq_invalid_argument;

    row_count.* = manager.resultSetRowCount(result_set_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_result_set_affected_rows(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_affected_rows: ?*u64,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const affected_rows = out_affected_rows orelse return aq_invalid_argument;

    affected_rows.* = manager.resultSetAffectedRows(result_set_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_result_set_column_count(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    out_column_count: ?*usize,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const column_count = out_column_count orelse return aq_invalid_argument;

    column_count.* = manager.resultSetColumnCount(result_set_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_result_set_column_metadata(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    column_index: usize,
    out_metadata: ?*AqColumnMetadata,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const metadata_out = out_metadata orelse return aq_invalid_argument;

    const metadata = manager.resultSetColumn(result_set_id, column_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    fillColumnMetadata(metadata_out, metadata);

    return aq_ok;
}

pub fn aq_result_set_value(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    row_index: usize,
    column_index: usize,
    out_cell: ?*AqResultCell,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const cell_out = out_cell orelse return aq_invalid_argument;

    const cell = manager.resultSetCell(result_set_id, row_index, column_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    fillResultCell(cell_out, cell);

    return aq_ok;
}

pub fn aq_cursor_open(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const sql_value = sql orelse return 0;
    adbc_backend.clearLastDriverErrorMessage();

    const cursor = manager.openCursor(connection_id, std.mem.span(sql_value)) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
    return cursor.id;
}

pub fn aq_cursor_open_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    clearManagerError(manager);
    const sql_value = sql orelse return 0;

    return manager.openCursorAsync(connection_id, std.mem.span(sql_value)) catch |err| {
        setManagerError(manager, err);
        return 0;
    };
}

pub fn aq_operation_await(
    raw_manager: ?*anyopaque,
    operation_id: u64,
    out_result: ?*AqOperationResult,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const result_out = out_result orelse return aq_invalid_argument;

    const result = manager.awaitOperation(operation_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    result_out.* = .{
        .state = @intFromEnum(switch (result.state) {
            .pending => AqOperationState.pending,
            .running => AqOperationState.running,
            .succeeded => AqOperationState.succeeded,
            .failed => AqOperationState.failed,
        }),
        .status = if (result.failure) |failure| mapError(failure) else aq_ok,
        .value = result.value,
    };

    return aq_ok;
}

pub fn aq_cursor_next(raw_manager: ?*anyopaque, cursor_id: u64, out_has_row: ?*u8) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const has_row = out_has_row orelse return aq_invalid_argument;

    has_row.* = if (manager.fetchNext(cursor_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    }) 1 else 0;

    return aq_ok;
}

pub fn aq_cursor_close(raw_manager: ?*anyopaque, cursor_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);

    manager.closeCursor(cursor_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_cursor_column_count(
    raw_manager: ?*anyopaque,
    cursor_id: u64,
    out_column_count: ?*usize,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const column_count = out_column_count orelse return aq_invalid_argument;

    column_count.* = manager.cursorColumnCount(cursor_id) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    return aq_ok;
}

pub fn aq_cursor_column_metadata(
    raw_manager: ?*anyopaque,
    cursor_id: u64,
    column_index: usize,
    out_metadata: ?*AqColumnMetadata,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const metadata_out = out_metadata orelse return aq_invalid_argument;

    const metadata = manager.cursorColumn(cursor_id, column_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    fillColumnMetadata(metadata_out, metadata);

    return aq_ok;
}

pub fn aq_last_error_message(
    raw_manager: ?*anyopaque,
    out_message: ?*AqErrorMessage,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    const error_out = out_message orelse return aq_invalid_argument;

    if (manager.lastErrorMessage()) |message| {
        error_out.* = .{
            .message_ptr = message.ptr,
            .message_len = message.len,
        };
    } else {
        error_out.* = .{
            .message_ptr = null,
            .message_len = 0,
        };
    }

    return aq_ok;
}
