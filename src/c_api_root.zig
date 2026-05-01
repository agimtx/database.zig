const ffi = @import("ffi/c_api.zig");

export fn aq_manager_create() ?*anyopaque {
    return ffi.aq_manager_create();
}

export fn aq_manager_destroy(raw_manager: ?*anyopaque) void {
    ffi.aq_manager_destroy(raw_manager);
}

export fn aq_connection_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return ffi.aq_connection_open(raw_manager, driver_kind, dsn);
}

export fn aq_connection_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return ffi.aq_connection_open_async(raw_manager, driver_kind, dsn);
}

export fn aq_manager_open(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return ffi.aq_manager_open(raw_manager, driver_kind, dsn);
}

export fn aq_manager_open_async(raw_manager: ?*anyopaque, driver_kind: i32, dsn: ?[*:0]const u8) u64 {
    return ffi.aq_manager_open_async(raw_manager, driver_kind, dsn);
}

export fn aq_connection_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    return ffi.aq_connection_close(raw_manager, connection_id);
}

export fn aq_manager_close(raw_manager: ?*anyopaque, connection_id: u64) i32 {
    return ffi.aq_manager_close(raw_manager, connection_id);
}

export fn aq_connection_execute(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    return ffi.aq_connection_execute(raw_manager, connection_id, sql);
}

export fn aq_connection_execute_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    return ffi.aq_connection_execute_async(raw_manager, connection_id, sql);
}

export fn aq_connection_test(raw_manager: ?*anyopaque, connection_id: u64, out_ok: ?*u8) i32 {
    return ffi.aq_connection_test(raw_manager, connection_id, out_ok);
}

export fn aq_connection_get_tables(
    raw_manager: ?*anyopaque,
    connection_id: u64,
    catalog: ?[*:0]const u8,
    database: ?[*:0]const u8,
) u64 {
    return ffi.aq_connection_get_tables(raw_manager, connection_id, catalog, database);
}

export fn aq_connection_get_catalogs(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    return ffi.aq_connection_get_catalogs(raw_manager, connection_id);
}

export fn aq_connection_get_databases(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    return ffi.aq_connection_get_databases(raw_manager, connection_id);
}

export fn aq_connection_get_database(raw_manager: ?*anyopaque, connection_id: u64) u64 {
    return ffi.aq_connection_get_database(raw_manager, connection_id);
}

export fn aq_connection_inspect_namespace_access(
    raw_manager: ?*anyopaque,
    connection_id: u64,
    catalog: ?[*:0]const u8,
    database: ?[*:0]const u8,
    out_access: ?*ffi.AqNamespaceAccess,
) i32 {
    return ffi.aq_connection_inspect_namespace_access(raw_manager, connection_id, catalog, database, out_access);
}

export fn aq_result_set_close(raw_manager: ?*anyopaque, result_set_id: u64) i32 {
    return ffi.aq_result_set_close(raw_manager, result_set_id);
}

export fn aq_result_set_row_count(raw_manager: ?*anyopaque, result_set_id: u64, out_row_count: ?*u64) i32 {
    return ffi.aq_result_set_row_count(raw_manager, result_set_id, out_row_count);
}

export fn aq_result_set_affected_rows(raw_manager: ?*anyopaque, result_set_id: u64, out_affected_rows: ?*u64) i32 {
    return ffi.aq_result_set_affected_rows(raw_manager, result_set_id, out_affected_rows);
}

export fn aq_result_set_column_count(raw_manager: ?*anyopaque, result_set_id: u64, out_column_count: ?*usize) i32 {
    return ffi.aq_result_set_column_count(raw_manager, result_set_id, out_column_count);
}

export fn aq_result_set_column_metadata(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    column_index: usize,
    out_metadata: ?*ffi.AqColumnMetadata,
) i32 {
    return ffi.aq_result_set_column_metadata(raw_manager, result_set_id, column_index, out_metadata);
}

export fn aq_result_set_value(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    row_index: usize,
    column_index: usize,
    out_cell: ?*ffi.AqResultCell,
) i32 {
    return ffi.aq_result_set_value(raw_manager, result_set_id, row_index, column_index, out_cell);
}

export fn aq_result_set_table_qualified_name(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    row_index: usize,
    out_name: ?*ffi.AqQualifiedName,
) i32 {
    return ffi.aq_result_set_table_qualified_name(raw_manager, result_set_id, row_index, out_name);
}

export fn aq_cursor_open(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    return ffi.aq_cursor_open(raw_manager, connection_id, sql);
}

export fn aq_cursor_open_async(raw_manager: ?*anyopaque, connection_id: u64, sql: ?[*:0]const u8) u64 {
    return ffi.aq_cursor_open_async(raw_manager, connection_id, sql);
}

export fn aq_operation_await(
    raw_manager: ?*anyopaque,
    operation_id: u64,
    out_result: ?*ffi.AqOperationResult,
) i32 {
    return ffi.aq_operation_await(raw_manager, operation_id, out_result);
}

export fn aq_last_error_message(
    raw_manager: ?*anyopaque,
    out_message: ?*ffi.AqErrorMessage,
) i32 {
    return ffi.aq_last_error_message(raw_manager, out_message);
}

export fn aq_cursor_next(raw_manager: ?*anyopaque, cursor_id: u64, out_has_row: ?*u8) i32 {
    return ffi.aq_cursor_next(raw_manager, cursor_id, out_has_row);
}

export fn aq_cursor_close(raw_manager: ?*anyopaque, cursor_id: u64) i32 {
    return ffi.aq_cursor_close(raw_manager, cursor_id);
}

export fn aq_cursor_column_count(raw_manager: ?*anyopaque, cursor_id: u64, out_column_count: ?*usize) i32 {
    return ffi.aq_cursor_column_count(raw_manager, cursor_id, out_column_count);
}

export fn aq_cursor_column_metadata(
    raw_manager: ?*anyopaque,
    cursor_id: u64,
    column_index: usize,
    out_metadata: ?*ffi.AqColumnMetadata,
) i32 {
    return ffi.aq_cursor_column_metadata(raw_manager, cursor_id, column_index, out_metadata);
}
