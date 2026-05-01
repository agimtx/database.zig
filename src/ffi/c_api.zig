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
    raw_type_ptr: ?[*]const u8,
    raw_type_len: usize,
    column_type: i32,
    nullable: u8,
};

pub const AqQualifiedNamePart = extern struct {
    role: i32,
    value_ptr: ?[*]const u8,
    value_len: usize,
};

pub const AqQualifiedName = extern struct {
    part_count: usize,
    formatted_ptr: ?[*]const u8,
    formatted_len: usize,
    parts: [3]AqQualifiedNamePart,
};

pub const AqNamespaceAccess = extern struct {
    namespace_role: i32,
    can_get_schema: u8,
    has_catalog_access: u8,
    has_namespace_access: u8,
    qualified_name: AqQualifiedName,
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

threadlocal var namespace_access_scratch: [3]?[]u8 = .{ null, null, null };

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
        .raw_type_ptr = if (metadata.raw_type) |raw_type| raw_type.ptr else null,
        .raw_type_len = if (metadata.raw_type) |raw_type| raw_type.len else 0,
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

fn clearQualifiedName(out_name: *AqQualifiedName) void {
    out_name.* = .{
        .part_count = 0,
        .formatted_ptr = null,
        .formatted_len = 0,
        .parts = .{
            .{ .role = @intFromEnum(root.QualifiedNamePartRole.catalog), .value_ptr = null, .value_len = 0 },
            .{ .role = @intFromEnum(root.QualifiedNamePartRole.catalog), .value_ptr = null, .value_len = 0 },
            .{ .role = @intFromEnum(root.QualifiedNamePartRole.catalog), .value_ptr = null, .value_len = 0 },
        },
    };
}

fn clearNamespaceAccess(out_access: *AqNamespaceAccess) void {
    out_access.namespace_role = @intFromEnum(root.QualifiedNamePartRole.database);
    out_access.can_get_schema = 0;
    out_access.has_catalog_access = 0;
    out_access.has_namespace_access = 0;
    clearQualifiedName(&out_access.qualified_name);
}

fn clearNamespaceAccessScratch() void {
    for (&namespace_access_scratch) |*slot| {
        if (slot.*) |value| {
            ffi_allocator.free(value);
            slot.* = null;
        }
    }
}

fn storeNamespaceAccessScratch(index: usize, value: []const u8) ![]const u8 {
    const owned = try ffi_allocator.dupe(u8, value);
    namespace_access_scratch[index] = owned;
    return owned;
}

fn fillQualifiedNamePart(out_part: *AqQualifiedNamePart, role: root.QualifiedNamePartRole, value: []const u8) void {
    out_part.* = .{
        .role = @intFromEnum(role),
        .value_ptr = value.ptr,
        .value_len = value.len,
    };
}

fn findResultSetColumnIndex(
    manager: *root.ConnectionManager,
    result_set_id: u64,
    expected_name: []const u8,
) !usize {
    const count = try manager.resultSetColumnCount(result_set_id);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const column = try manager.resultSetColumn(result_set_id, index);
        if (std.mem.eql(u8, column.name, expected_name)) {
            return index;
        }
    }

    return error.InvalidArgument;
}

fn qualifiedNameRoleFromText(text: []const u8) ?root.QualifiedNamePartRole {
    if (std.mem.eql(u8, text, "catalog")) return .catalog;
    if (std.mem.eql(u8, text, "database")) return .database;
    if (std.mem.eql(u8, text, "schema")) return .schema;
    if (std.mem.eql(u8, text, "dataset")) return .dataset;
    if (std.mem.eql(u8, text, "namespace")) return .namespace;
    if (std.mem.eql(u8, text, "object")) return .object;
    return null;
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

pub fn aq_connection_inspect_namespace_access(
    raw_manager: ?*anyopaque,
    connection_id: u64,
    catalog: ?[*:0]const u8,
    database: ?[*:0]const u8,
    out_access: ?*AqNamespaceAccess,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const access_out = out_access orelse return aq_invalid_argument;
    clearNamespaceAccess(access_out);
    clearNamespaceAccessScratch();

    const access = manager.inspectNamespaceAccess(connection_id, .{
        .catalog = if (catalog) |value| std.mem.span(value) else null,
        .database = if (database) |value| std.mem.span(value) else null,
    }) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    access_out.namespace_role = @intFromEnum(access.namespace_role);
    access_out.can_get_schema = if (access.can_get_schema) 1 else 0;
    access_out.has_catalog_access = if (access.has_catalog_access) 1 else 0;
    access_out.has_namespace_access = if (access.has_namespace_access) 1 else 0;
    access_out.qualified_name.part_count = access.part_count;
    var index: usize = 0;
    while (index < access.part_count and index < access.parts.len) : (index += 1) {
        const owned_value = storeNamespaceAccessScratch(index, access.parts[index].value) catch |err| {
            setManagerError(manager, err);
            clearNamespaceAccess(access_out);
            clearNamespaceAccessScratch();
            return mapError(err);
        };
        fillQualifiedNamePart(
            &access_out.qualified_name.parts[index],
            access.parts[index].role,
            owned_value,
        );
    }

    const formatted = access.qualifiedName().format(ffi_allocator, ".") catch |err| {
        setManagerError(manager, err);
        clearNamespaceAccess(access_out);
        clearNamespaceAccessScratch();
        return mapError(err);
    };
    namespace_access_scratch[2] = formatted;
    access_out.qualified_name.formatted_ptr = formatted.ptr;
    access_out.qualified_name.formatted_len = formatted.len;

    return aq_ok;
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

pub fn aq_result_set_table_qualified_name(
    raw_manager: ?*anyopaque,
    result_set_id: u64,
    row_index: usize,
    out_name: ?*AqQualifiedName,
) i32 {
    const manager = castManager(raw_manager) orelse return aq_invalid_argument;
    clearManagerError(manager);
    const qualified_name_out = out_name orelse return aq_invalid_argument;
    clearQualifiedName(qualified_name_out);

    const catalog_index = findResultSetColumnIndex(manager, result_set_id, "catalog_name") catch {
        manager.setLastErrorCopy("result set does not expose catalog_name") catch {};
        return aq_invalid_argument;
    };
    const namespace_index = findResultSetColumnIndex(manager, result_set_id, "database_name") catch {
        manager.setLastErrorCopy("result set does not expose database_name") catch {};
        return aq_invalid_argument;
    };
    const object_index = findResultSetColumnIndex(manager, result_set_id, "table_name") catch {
        manager.setLastErrorCopy("result set does not expose table_name") catch {};
        return aq_invalid_argument;
    };
    const namespace_kind_index = findResultSetColumnIndex(manager, result_set_id, "namespace_kind") catch {
        manager.setLastErrorCopy("result set does not expose namespace_kind") catch {};
        return aq_invalid_argument;
    };
    const formatted_index = findResultSetColumnIndex(manager, result_set_id, "qualified_name") catch {
        manager.setLastErrorCopy("result set does not expose qualified_name") catch {};
        return aq_invalid_argument;
    };

    const catalog = manager.resultSetCell(result_set_id, row_index, catalog_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    const namespace_value = manager.resultSetCell(result_set_id, row_index, namespace_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    const object_value = manager.resultSetCell(result_set_id, row_index, object_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    const namespace_kind = manager.resultSetCell(result_set_id, row_index, namespace_kind_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };
    const formatted = manager.resultSetCell(result_set_id, row_index, formatted_index) catch |err| {
        setManagerError(manager, err);
        return mapError(err);
    };

    const namespace_role = qualifiedNameRoleFromText(namespace_kind.text) orelse {
        manager.setLastErrorCopy("unsupported namespace_kind value") catch {};
        return aq_invalid_argument;
    };

    var part_count: usize = 0;
    if (!catalog.is_null and catalog.text.len != 0) {
        fillQualifiedNamePart(&qualified_name_out.parts[part_count], .catalog, catalog.text);
        part_count += 1;
    }
    if (!namespace_value.is_null and namespace_value.text.len != 0) {
        fillQualifiedNamePart(&qualified_name_out.parts[part_count], namespace_role, namespace_value.text);
        part_count += 1;
    }
    if (!object_value.is_null and object_value.text.len != 0) {
        fillQualifiedNamePart(&qualified_name_out.parts[part_count], .object, object_value.text);
        part_count += 1;
    }

    qualified_name_out.part_count = part_count;
    if (!formatted.is_null) {
        qualified_name_out.formatted_ptr = formatted.text.ptr;
        qualified_name_out.formatted_len = formatted.text.len;
    }

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

fn textFromPointer(pointer: ?[*]const u8, len: usize) []const u8 {
    if (pointer) |value| {
        return value[0..len];
    }

    return "";
}

test "c api exposes table qualified name metadata" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    const raw_manager = aq_manager_create() orelse return error.OutOfMemory;
    defer aq_manager_destroy(raw_manager);

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);
    const dsn_z = try std.testing.allocator.dupeZ(u8, dsn);
    defer std.testing.allocator.free(dsn_z);

    const connection_id = aq_connection_open(raw_manager, 1, dsn_z.ptr);
    try std.testing.expect(connection_id != 0);
    defer {
        std.testing.expectEqual(aq_ok, aq_connection_close(raw_manager, connection_id)) catch unreachable;
    }

    const create_sql = try std.testing.allocator.dupeZ(u8, "create table c_api_records (id integer)");
    defer std.testing.allocator.free(create_sql);
    const create_result = aq_connection_execute(raw_manager, connection_id, create_sql.ptr);
    try std.testing.expect(create_result != 0);
    try std.testing.expectEqual(aq_ok, aq_result_set_close(raw_manager, create_result));

    const main_z = try std.testing.allocator.dupeZ(u8, "main");
    defer std.testing.allocator.free(main_z);
    const tables_id = aq_connection_get_tables(raw_manager, connection_id, null, main_z.ptr);
    try std.testing.expect(tables_id != 0);
    defer {
        std.testing.expectEqual(aq_ok, aq_result_set_close(raw_manager, tables_id)) catch unreachable;
    }

    var row_count: u64 = 0;
    try std.testing.expectEqual(aq_ok, aq_result_set_row_count(raw_manager, tables_id, &row_count));

    var matched = false;
    var row_index: usize = 0;
    while (row_index < row_count) : (row_index += 1) {
        var cell = AqResultCell{ .text_ptr = undefined, .text_len = 0, .is_null = 0 };
        try std.testing.expectEqual(aq_ok, aq_result_set_value(raw_manager, tables_id, row_index, 2, &cell));
        if (!std.mem.eql(u8, cell.text_ptr[0..cell.text_len], "c_api_records")) {
            continue;
        }

        var qualified_name: AqQualifiedName = undefined;
        try std.testing.expectEqual(aq_ok, aq_result_set_table_qualified_name(raw_manager, tables_id, row_index, &qualified_name));
        try std.testing.expectEqual(@as(usize, 2), qualified_name.part_count);
        try std.testing.expectEqualStrings("main.c_api_records", textFromPointer(qualified_name.formatted_ptr, qualified_name.formatted_len));
        try std.testing.expectEqual(@as(i32, @intFromEnum(root.QualifiedNamePartRole.database)), qualified_name.parts[0].role);
        try std.testing.expectEqualStrings("main", textFromPointer(qualified_name.parts[0].value_ptr, qualified_name.parts[0].value_len));
        try std.testing.expectEqual(@as(i32, @intFromEnum(root.QualifiedNamePartRole.object)), qualified_name.parts[1].role);
        try std.testing.expectEqualStrings("c_api_records", textFromPointer(qualified_name.parts[1].value_ptr, qualified_name.parts[1].value_len));
        matched = true;
        break;
    }

    try std.testing.expect(matched);
}

test "c api exposes namespace access metadata" {
    if (!adbc_backend.sqliteDriverUsable(std.testing.allocator)) {
        return error.SkipZigTest;
    }

    const raw_manager = aq_manager_create() orelse return error.OutOfMemory;
    defer aq_manager_destroy(raw_manager);

    const dsn = try adbc_backend.testSqliteDsn(std.testing.allocator);
    defer std.testing.allocator.free(dsn);
    const dsn_z = try std.testing.allocator.dupeZ(u8, dsn);
    defer std.testing.allocator.free(dsn_z);

    const connection_id = aq_connection_open(raw_manager, 1, dsn_z.ptr);
    try std.testing.expect(connection_id != 0);
    defer {
        std.testing.expectEqual(aq_ok, aq_connection_close(raw_manager, connection_id)) catch unreachable;
    }

    const main_z = try std.testing.allocator.dupeZ(u8, "main");
    defer std.testing.allocator.free(main_z);

    var access: AqNamespaceAccess = undefined;
    try std.testing.expectEqual(
        aq_ok,
        aq_connection_inspect_namespace_access(raw_manager, connection_id, null, main_z.ptr, &access),
    );
    try std.testing.expectEqual(@as(i32, @intFromEnum(root.QualifiedNamePartRole.database)), access.namespace_role);
    try std.testing.expectEqual(@as(u8, 0), access.can_get_schema);
    try std.testing.expectEqual(@as(u8, 1), access.has_namespace_access);
    try std.testing.expectEqual(@as(usize, 1), access.qualified_name.part_count);
    try std.testing.expectEqualStrings("main", textFromPointer(access.qualified_name.parts[0].value_ptr, access.qualified_name.parts[0].value_len));
    try std.testing.expectEqual(@as(usize, 0), access.qualified_name.formatted_len);
}
