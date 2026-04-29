const std = @import("std");
const root = @import("../root.zig");

pub const dbz_ok: i32 = 0;
pub const dbz_invalid_argument: i32 = 1;
pub const dbz_driver_not_registered: i32 = 2;
pub const dbz_connection_not_found: i32 = 3;
pub const dbz_result_set_not_found: i32 = 4;
pub const dbz_cursor_not_found: i32 = 5;
pub const dbz_column_index_out_of_bounds: i32 = 6;
pub const dbz_internal_error: i32 = 255;

pub const DbzColumnMetadata = extern struct {
    name_ptr: [*]const u8,
    name_len: usize,
    column_type: i32,
    nullable: u8,
};

const ffi_allocator = std.heap.page_allocator;

fn castManager(raw_manager: ?*anyopaque) ?*root.ConnectionManager {
    const opaque_ptr = raw_manager orelse return null;
    return @ptrCast(@alignCast(opaque_ptr));
}

fn driverFromInt(value: i32) ?root.DriverKind {
    return switch (value) {
        1 => .mysql8,
        2 => .postgresql,
        3 => .sqlserver,
        4 => .snowflake,
        5 => .bigquery,
        6 => .duckdb,
        7 => .clickhouse,
        8 => .redshift,
        9 => .databricks,
        10 => .trino,
        else => null,
    };
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.DriverNotRegistered => dbz_driver_not_registered,
        error.ConnectionNotFound => dbz_connection_not_found,
        error.ResultSetNotFound => dbz_result_set_not_found,
        error.CursorNotFound => dbz_cursor_not_found,
        error.ColumnIndexOutOfBounds => dbz_column_index_out_of_bounds,
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

export fn dbz_manager_create() ?*anyopaque {
    const manager = ffi_allocator.create(root.ConnectionManager) catch return null;
    manager.* = root.ConnectionManager.init(ffi_allocator) catch {
        ffi_allocator.destroy(manager);
        return null;
    };
    return @ptrCast(manager);
}

export fn dbz_manager_destroy(raw_manager: ?*anyopaque) void {
    const manager = castManager(raw_manager) orelse return;
    manager.deinit();
    ffi_allocator.destroy(manager);
}

export fn dbz_connection_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const kind = driverFromInt(driver_kind) orelse return 0;
    const dsn_value = dsn orelse return 0;

    const handle = manager.open(.{
        .driver = kind,
        .dsn = std.mem.span(dsn_value),
    }) catch return 0;

    return handle.id;
}

export fn dbz_manager_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return dbz_connection_open(raw_manager, driver_kind, dsn);
}

export fn dbz_connection_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.close(connection_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

export fn dbz_manager_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    return dbz_connection_close(raw_manager, connection_id);
}

export fn dbz_connection_execute(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    const result_set = manager.execute(connection_id, std.mem.span(sql_value)) catch return 0;
    return result_set.id;
}

export fn dbz_result_set_close(raw_manager: ?*anyopaque, result_set_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.closeResultSet(result_set_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

export fn dbz_result_set_row_count(
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

export fn dbz_result_set_affected_rows(
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

export fn dbz_result_set_column_count(
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

export fn dbz_result_set_column_metadata(
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

export fn dbz_cursor_open(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    const manager = castManager(raw_manager) orelse return 0;
    const sql_value = sql orelse return 0;

    const cursor = manager.openCursor(connection_id, std.mem.span(sql_value)) catch return 0;
    return cursor.id;
}

export fn dbz_cursor_next(raw_manager: ?*anyopaque, cursor_id: u64, out_has_row: ?*u8) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;
    const has_row = out_has_row orelse return dbz_invalid_argument;

    has_row.* = if (manager.fetchNext(cursor_id) catch |err| {
        return mapError(err);
    }) 1 else 0;

    return dbz_ok;
}

export fn dbz_cursor_close(raw_manager: ?*anyopaque, cursor_id: u64) i32 {
    const manager = castManager(raw_manager) orelse return dbz_invalid_argument;

    manager.closeCursor(cursor_id) catch |err| {
        return mapError(err);
    };

    return dbz_ok;
}

export fn dbz_cursor_column_count(
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

export fn dbz_cursor_column_metadata(
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
