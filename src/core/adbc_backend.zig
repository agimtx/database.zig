const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const driver = @import("driver.zig");

pub const Error = error{
    InvalidArgument,
    DriverLoadFailed,
    MissingSymbol,
    QueryFailed,
};

const adbc_status_ok: u8 = 0;
const adbc_status_invalid_argument: u8 = 5;
const adbc_status_invalid_state: u8 = 6;
const adbc_version_1_1_0: c_int = 1001000;

const adbc_load_flag_search_env: u32 = 1;
const adbc_load_flag_search_user: u32 = 2;
const adbc_load_flag_search_system: u32 = 4;
const adbc_load_flag_allow_relative_paths: u32 = 8;
const adbc_load_flag_default: u32 = adbc_load_flag_search_env | adbc_load_flag_search_user | adbc_load_flag_search_system | adbc_load_flag_allow_relative_paths;

const arrow_flag_nullable: i64 = 2;

const reserved_option_driver = "driver";
const reserved_option_uri = "uri";
const reserved_option_entrypoint = "entrypoint";
const reserved_option_additional_search_path = "additional_manifest_search_path_list";
const arrow_extension_name_key = "ARROW:extension:name";
const postgres_typname_key = "ADBC:postgresql:typname";

const DbSetOptionFn = *const fn (*AdbcDatabase, [*:0]const u8, [*:0]const u8, ?*AdbcError) callconv(.c) u8;
const DbNewFn = *const fn (*AdbcDatabase, ?*AdbcError) callconv(.c) u8;
const DbInitFn = *const fn (*AdbcDatabase, ?*AdbcError) callconv(.c) u8;
const DbReleaseFn = *const fn (*AdbcDatabase, ?*AdbcError) callconv(.c) u8;
const CxnNewFn = *const fn (*AdbcConnection, ?*AdbcError) callconv(.c) u8;
const CxnInitFn = *const fn (*AdbcConnection, *AdbcDatabase, ?*AdbcError) callconv(.c) u8;
const CxnReleaseFn = *const fn (*AdbcConnection, ?*AdbcError) callconv(.c) u8;
const StmtNewFn = *const fn (*AdbcConnection, *AdbcStatement, ?*AdbcError) callconv(.c) u8;
const StmtSetSqlQueryFn = *const fn (*AdbcStatement, [*:0]const u8, ?*AdbcError) callconv(.c) u8;
const StmtExecuteQueryFn = *const fn (*AdbcStatement, *ArrowArrayStream, *i64, ?*AdbcError) callconv(.c) u8;
const StmtReleaseFn = *const fn (*AdbcStatement, ?*AdbcError) callconv(.c) u8;
const SetLoadFlagsFn = *const fn (*AdbcDatabase, u32, ?*AdbcError) callconv(.c) u8;
const SetAdditionalSearchPathFn = *const fn (*AdbcDatabase, [*:0]const u8, ?*AdbcError) callconv(.c) u8;

const ArrowSchemaReleaseFn = *const fn (*ArrowSchema) callconv(.c) void;
const ArrowArrayReleaseFn = *const fn (*ArrowArray) callconv(.c) void;
const ArrowArrayStreamGetSchemaFn = *const fn (*ArrowArrayStream, *ArrowSchema) callconv(.c) c_int;
const ArrowArrayStreamGetNextFn = *const fn (*ArrowArrayStream, *ArrowArray) callconv(.c) c_int;
const ArrowArrayStreamReleaseFn = *const fn (*ArrowArrayStream) callconv(.c) void;

const AdbcError = extern struct {
    message: ?[*:0]u8 = null,
    vendor_code: i32 = std.math.minInt(i32),
    sqlstate: [5]u8 = .{ 0, 0, 0, 0, 0 },
    release: ?*const fn (*AdbcError) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
    private_driver: ?*anyopaque = null,
};

threadlocal var last_driver_error_message: ?[]u8 = null;

const AdbcDatabase = extern struct {
    private_data: ?*anyopaque = null,
    private_driver: ?*anyopaque = null,
};

const AdbcConnection = extern struct {
    private_data: ?*anyopaque = null,
    private_driver: ?*anyopaque = null,
};

const AdbcStatement = extern struct {
    private_data: ?*anyopaque = null,
    private_driver: ?*anyopaque = null,
};

const ArrowSchema = extern struct {
    format: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    metadata: ?[*:0]const u8 = null,
    flags: i64 = 0,
    n_children: i64 = 0,
    children: [*c]?*ArrowSchema = null,
    dictionary: ?*ArrowSchema = null,
    release: ?ArrowSchemaReleaseFn = null,
    private_data: ?*anyopaque = null,
};

const ArrowArray = extern struct {
    length: i64 = 0,
    null_count: i64 = 0,
    offset: i64 = 0,
    n_buffers: i64 = 0,
    n_children: i64 = 0,
    buffers: [*c]?*const anyopaque = null,
    children: [*c]?*ArrowArray = null,
    dictionary: ?*ArrowArray = null,
    release: ?ArrowArrayReleaseFn = null,
    private_data: ?*anyopaque = null,
};

const ArrowArrayStream = extern struct {
    get_schema: ?ArrowArrayStreamGetSchemaFn = null,
    get_next: ?ArrowArrayStreamGetNextFn = null,
    get_last_error: ?*const fn (*ArrowArrayStream) callconv(.c) ?[*:0]const u8 = null,
    release: ?ArrowArrayStreamReleaseFn = null,
    private_data: ?*anyopaque = null,
};

const Runtime = struct {
    manager_lib: std.DynLib,
    db_new: DbNewFn,
    db_set_option: DbSetOptionFn,
    db_init: DbInitFn,
    db_release: DbReleaseFn,
    cxn_new: CxnNewFn,
    cxn_init: CxnInitFn,
    cxn_release: CxnReleaseFn,
    stmt_new: StmtNewFn,
    stmt_set_sql_query: StmtSetSqlQueryFn,
    stmt_execute_query: StmtExecuteQueryFn,
    stmt_release: StmtReleaseFn,
    set_load_flags: SetLoadFlagsFn,
    set_additional_search_path: SetAdditionalSearchPathFn,

    fn init(path: []const u8) !Runtime {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        return .{
            .manager_lib = lib,
            .db_new = lookup(&lib, DbNewFn, "AdbcDatabaseNew"),
            .db_set_option = lookup(&lib, DbSetOptionFn, "AdbcDatabaseSetOption"),
            .db_init = lookup(&lib, DbInitFn, "AdbcDatabaseInit"),
            .db_release = lookup(&lib, DbReleaseFn, "AdbcDatabaseRelease"),
            .cxn_new = lookup(&lib, CxnNewFn, "AdbcConnectionNew"),
            .cxn_init = lookup(&lib, CxnInitFn, "AdbcConnectionInit"),
            .cxn_release = lookup(&lib, CxnReleaseFn, "AdbcConnectionRelease"),
            .stmt_new = lookup(&lib, StmtNewFn, "AdbcStatementNew"),
            .stmt_set_sql_query = lookup(&lib, StmtSetSqlQueryFn, "AdbcStatementSetSqlQuery"),
            .stmt_execute_query = lookup(&lib, StmtExecuteQueryFn, "AdbcStatementExecuteQuery"),
            .stmt_release = lookup(&lib, StmtReleaseFn, "AdbcStatementRelease"),
            .set_load_flags = lookup(&lib, SetLoadFlagsFn, "AdbcDriverManagerDatabaseSetLoadFlags"),
            .set_additional_search_path = lookup(&lib, SetAdditionalSearchPathFn, "AdbcDriverManagerDatabaseSetAdditionalSearchPathList"),
        };
    }

    fn deinit(self: *Runtime) void {
        self.manager_lib.close();
    }
};

const ConnectionContext = struct {
    runtime: Runtime,
    database: AdbcDatabase = .{},
    connection: AdbcConnection = .{},
    dependency_handle: ?*anyopaque = null,
    vendor_name: []const u8 = "adbc",
};

const ParsedOption = struct {
    key: []const u8,
    value: []const u8,
};

const ParsedDsn = struct {
    driver: ?[]const u8 = null,
    entrypoint: ?[]const u8 = null,
    additional_search_path: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    options: std.ArrayListUnmanaged(ParsedOption) = .{},

    fn deinit(self: *ParsedDsn, allocator: std.mem.Allocator) void {
        self.options.deinit(allocator);
    }
};

pub fn open(
    allocator: std.mem.Allocator,
    connection_id: u64,
    options: types.ConnectOptions,
) !*driver.ConnectionHandle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var parsed = try parseDsn(temp, options.dsn);
    defer parsed.deinit(temp);

    const manager_path = try resolveDriverManagerPath(temp);
    const vendor_driver_path = try resolveVendorDriverPath(temp, parsed, options.dsn);
    const inferred_driver_name = inferDriverName(parsed.uri orelse options.dsn);

    var context = try allocator.create(ConnectionContext);
    errdefer allocator.destroy(context);
    context.* = .{
        .runtime = try Runtime.init(manager_path),
        .vendor_name = inferred_driver_name orelse "adbc",
    };
    errdefer context.runtime.deinit();

    context.dependency_handle = try preloadVendorDependencies(temp, vendor_driver_path);
    errdefer {
        if (context.dependency_handle) |handle_dependency| {
            _ = dlclose(handle_dependency);
        }
    }

    var error_info = AdbcError{};
    try requireOk(context.runtime.db_new(&context.database, &error_info), &error_info);
    errdefer releaseDatabase(context);

    try requireOk(context.runtime.set_load_flags(&context.database, adbc_load_flag_default, &error_info), &error_info);

    const search_path = parsed.additional_search_path orelse try defaultAdditionalSearchPath(temp);
    if (search_path.len != 0) {
        try withSentinel(temp, search_path, struct {
            fn apply(runtime: *const Runtime, database: *AdbcDatabase, value: [*:0]const u8, error_info_inner: *AdbcError) !void {
                try requireOk(runtime.set_additional_search_path(database, value, error_info_inner), error_info_inner);
            }
        }.apply, &context.runtime, &context.database, &error_info);
    }

    try setDatabaseOption(temp, &context.runtime, &context.database, reserved_option_driver, vendor_driver_path, &error_info);
    if (parsed.entrypoint orelse defaultEntrypointForDriver(inferred_driver_name)) |entrypoint| {
        try setDatabaseOption(temp, &context.runtime, &context.database, reserved_option_entrypoint, entrypoint, &error_info);
    }
    if (parsed.uri) |uri| {
        try setDatabaseOption(temp, &context.runtime, &context.database, reserved_option_uri, uri, &error_info);
    }

    for (parsed.options.items) |item| {
        try setDatabaseOption(temp, &context.runtime, &context.database, item.key, item.value, &error_info);
    }

    if (options.username) |username| {
        try setDatabaseOption(temp, &context.runtime, &context.database, "username", username, &error_info);
    }
    if (options.password) |password| {
        try setDatabaseOption(temp, &context.runtime, &context.database, "password", password, &error_info);
    }
    if (options.database) |database| {
        try setDatabaseOption(temp, &context.runtime, &context.database, "database", database, &error_info);
    }

    try requireOk(context.runtime.db_init(&context.database, &error_info), &error_info);
    errdefer releaseConnection(context);

    try requireOk(context.runtime.cxn_new(&context.connection, &error_info), &error_info);
    try requireOk(context.runtime.cxn_init(&context.connection, &context.database, &error_info), &error_info);

    const handle = try allocator.create(driver.ConnectionHandle);
    errdefer allocator.destroy(handle);
    handle.* = .{
        .id = connection_id,
        .driver = options.driver,
        .opaque_handle = @intFromPtr(context),
        .state = .open,
    };
    return handle;
}

pub fn close(allocator: std.mem.Allocator, handle: *driver.ConnectionHandle) void {
    const context = connectionContext(handle);
    releaseConnection(context);
    if (context.dependency_handle) |handle_dependency| {
        _ = dlclose(handle_dependency);
    }
    context.runtime.deinit();
    allocator.destroy(context);
    handle.state = .closed;
    allocator.destroy(handle);
}

pub fn execute(
    allocator: std.mem.Allocator,
    handle: *driver.ConnectionHandle,
    result_set_id: u64,
    sql: []const u8,
) !*driver.ResultSetHandle {
    const context = connectionContext(handle);
    const consumed = try executeStatement(allocator, context, sql);
    errdefer consumed.deinit(allocator);

    const result_set = try allocator.create(driver.ResultSetHandle);
    result_set.* = .{
        .id = result_set_id,
        .connection_id = handle.id,
        .columns = consumed.columns,
        .rows = consumed.rows,
        .row_count = consumed.row_count,
        .affected_rows = consumed.affected_rows,
    };
    return result_set;
}

pub fn testConnection(allocator: std.mem.Allocator, handle: *driver.ConnectionHandle) !bool {
    const context = connectionContext(handle);
    const consumed = try executeStatement(allocator, context, "select 1 as ok");
    defer consumed.deinit(allocator);
    return true;
}

pub fn closeResultSet(allocator: std.mem.Allocator, handle: *driver.ResultSetHandle) void {
    freeRows(allocator, handle.rows);
    freeColumns(allocator, handle.columns);
    allocator.destroy(handle);
}

pub fn getTables(
    allocator: std.mem.Allocator,
    handle: *driver.ConnectionHandle,
    result_set_id: u64,
    options: types.GetTablesOptions,
) !*driver.ResultSetHandle {
    const context = connectionContext(handle);
    const sql = try buildGetTablesSql(allocator, context.vendor_name, options);
    defer allocator.free(sql);

    const result_set = try execute(allocator, handle, result_set_id, sql);
    errdefer closeResultSet(allocator, result_set);

    try appendTableQualifiedNames(allocator, context.vendor_name, result_set);
    return result_set;
}

pub fn getDatabases(
    allocator: std.mem.Allocator,
    handle: *driver.ConnectionHandle,
    result_set_id: u64,
) !*driver.ResultSetHandle {
    const context = connectionContext(handle);
    const sql = try buildGetDatabasesSql(allocator, context.vendor_name);
    defer allocator.free(sql);
    return execute(allocator, handle, result_set_id, sql);
}

pub fn openCursor(
    allocator: std.mem.Allocator,
    handle: *driver.ConnectionHandle,
    cursor_id: u64,
    sql: []const u8,
) !*driver.CursorHandle {
    const context = connectionContext(handle);
    const consumed = try executeStatement(allocator, context, sql);
    errdefer consumed.deinit(allocator);

    const cursor = try allocator.create(driver.CursorHandle);
    cursor.* = .{
        .id = cursor_id,
        .connection_id = handle.id,
        .columns = consumed.columns,
        .total_rows = @intCast(consumed.row_count),
    };
    return cursor;
}

pub fn fetchCursorNext(_: std.mem.Allocator, handle: *driver.CursorHandle) !bool {
    if (handle.position >= handle.total_rows) {
        return false;
    }

    handle.position += 1;
    return true;
}

pub fn closeCursor(allocator: std.mem.Allocator, handle: *driver.CursorHandle) void {
    freeColumns(allocator, handle.columns);
    allocator.destroy(handle);
}

pub fn testSqliteDsn(allocator: std.mem.Allocator) ![]u8 {
    const driver_path = try vendoredDriverPathAlloc(allocator, "sqlite");
    defer allocator.free(driver_path);
    return std.fmt.allocPrint(allocator, "driver={s};uri=file::memory:", .{driver_path});
}

pub fn sqliteDriverUsable(allocator: std.mem.Allocator) bool {
    const driver_path = vendoredDriverPathAlloc(allocator, "sqlite") catch return false;
    defer allocator.free(driver_path);

    const sentinel = allocator.dupeZ(u8, driver_path) catch return false;
    defer allocator.free(sentinel);

    const handle = dlopen(sentinel, globalDlopenFlags());
    if (handle) |loaded| {
        _ = dlclose(loaded);
        return true;
    }
    return false;
}

const ConsumedResult = struct {
    columns: []types.ColumnMetadata,
    rows: []types.ResultRow,
    row_count: u64,
    affected_rows: u64,

    fn deinit(self: ConsumedResult, allocator: std.mem.Allocator) void {
        freeRows(allocator, self.rows);
        freeColumns(allocator, self.columns);
    }
};

fn executeStatement(allocator: std.mem.Allocator, context: *ConnectionContext, sql: []const u8) !ConsumedResult {
    var statement = AdbcStatement{};
    var error_info = AdbcError{};

    try requireOk(context.runtime.stmt_new(&context.connection, &statement, &error_info), &error_info);
    defer _ = context.runtime.stmt_release(&statement, null);

    try withSentinel(allocator, sql, struct {
        fn apply(runtime: *const Runtime, stmt: *AdbcStatement, value: [*:0]const u8, error_info_inner: *AdbcError) !void {
            try requireOk(runtime.stmt_set_sql_query(stmt, value, error_info_inner), error_info_inner);
        }
    }.apply, &context.runtime, &statement, &error_info);

    var stream = ArrowArrayStream{};
    var affected_rows: i64 = -1;
    try requireOk(context.runtime.stmt_execute_query(&statement, &stream, &affected_rows, &error_info), &error_info);
    defer if (stream.release) |release| release(&stream);

    var schema = ArrowSchema{};
    const get_schema = stream.get_schema orelse return Error.QueryFailed;
    if (get_schema(&stream, &schema) != 0) {
        return Error.QueryFailed;
    }
    defer if (schema.release) |release| release(&schema);

    const columns = try columnsFromSchema(allocator, &schema);
    errdefer freeColumns(allocator, columns);

    var rows = std.ArrayList(types.ResultRow).empty;
    errdefer freeRows(allocator, rows.items);

    var row_count: u64 = 0;
    const get_next = stream.get_next orelse return Error.QueryFailed;
    while (true) {
        var array = ArrowArray{};
        if (get_next(&stream, &array) != 0) {
            return Error.QueryFailed;
        }
        if (array.release == null) {
            break;
        }
        try appendRowsFromArray(allocator, &rows, &schema, &array);
        row_count += @intCast(array.length);
        if (array.release) |release| {
            release(&array);
        }
    }

    return .{
        .columns = columns,
        .rows = try rows.toOwnedSlice(allocator),
        .row_count = row_count,
        .affected_rows = if (affected_rows >= 0) @intCast(affected_rows) else row_count,
    };
}

fn parseDsn(allocator: std.mem.Allocator, dsn: []const u8) !ParsedDsn {
    var parsed: ParsedDsn = .{};
    if (!std.mem.containsAtLeast(u8, dsn, 1, "=")) {
        parsed.uri = dsn;
        return parsed;
    }

    var iterator = std.mem.splitScalar(u8, dsn, ';');
    while (iterator.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;

        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse {
            parsed.uri = dsn;
            parsed.options.clearAndFree(allocator);
            return parsed;
        };

        const key = std.mem.trim(u8, trimmed[0..eq_index], " \t\r\n");
        const value = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r\n");

        if (std.mem.eql(u8, key, reserved_option_driver)) {
            parsed.driver = value;
        } else if (std.mem.eql(u8, key, reserved_option_uri)) {
            parsed.uri = value;
        } else if (std.mem.eql(u8, key, reserved_option_entrypoint)) {
            parsed.entrypoint = value;
        } else if (std.mem.eql(u8, key, reserved_option_additional_search_path)) {
            parsed.additional_search_path = value;
        } else {
            try parsed.options.append(allocator, .{ .key = key, .value = value });
        }
    }

    return parsed;
}

fn resolveDriverManagerPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "DATABASE_ZIG_ADBC_DRIVER_MANAGER")) |value| {
        return value;
    } else |_| {}
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ vendoredLibDir(), managerLibraryFilename() });
    defer allocator.free(relative);
    return std.fs.cwd().realpathAlloc(allocator, relative);
}

fn resolveVendorDriverPath(allocator: std.mem.Allocator, parsed: ParsedDsn, dsn: []const u8) ![]const u8 {
    if (parsed.driver) |driver_path| {
        return driver_path;
    }
    if (std.process.getEnvVarOwned(allocator, "DATABASE_ZIG_ADBC_DRIVER")) |value| {
        return value;
    } else |_| {}

    const inferred = inferDriverName(parsed.uri orelse dsn) orelse return Error.InvalidArgument;
    return vendoredDriverPathAlloc(allocator, inferred) catch |err| {
        if (std.mem.eql(u8, inferred, "mysql")) {
            return Error.InvalidArgument;
        }
        return err;
    };
}

fn inferDriverName(dsn: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOfScalar(u8, dsn, ':') orelse return null;
    const scheme = dsn[0..scheme_end];
    if (std.mem.eql(u8, scheme, "postgres") or std.mem.eql(u8, scheme, "postgresql")) return "postgresql";
    if (std.mem.eql(u8, scheme, "sqlite")) return "sqlite";
    if (std.mem.eql(u8, scheme, "snowflake")) return "snowflake";
    if (std.mem.eql(u8, scheme, "flightsql")) return "flightsql";
    if (std.mem.eql(u8, scheme, "mysql")) return "mysql";
    if (std.mem.eql(u8, scheme, "bigquery")) return "bigquery";
    if (std.mem.eql(u8, scheme, "mssql") or std.mem.eql(u8, scheme, "sqlserver")) return "mssql";
    if (std.mem.eql(u8, scheme, "redshift")) return "redshift";
    if (std.mem.eql(u8, scheme, "trino")) return "trino";
    if (std.mem.eql(u8, scheme, "databricks")) return "databricks";
    if (std.mem.eql(u8, scheme, "clickhouse")) return "clickhouse";
    if (std.mem.eql(u8, scheme, "exasol")) return "exasol";
    if (std.mem.eql(u8, scheme, "singlestore")) return "singlestore";
    return null;
}

fn defaultEntrypointForDriver(name: ?[]const u8) ?[]const u8 {
    const driver_name = name orelse return null;
    if (std.mem.eql(u8, driver_name, "exasol")) return "ExarrowDriverInit";
    return null;
}

fn defaultAdditionalSearchPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "DATABASE_ZIG_ADBC_SEARCH_PATH")) |value| {
        return value;
    } else |_| {}
    return std.fs.cwd().realpathAlloc(allocator, vendoredLibDir());
}

fn vendoredDriverPathAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ vendoredLibDir(), try libraryFilename(name) });
    defer allocator.free(relative);
    return std.fs.cwd().realpathAlloc(allocator, relative);
}

fn vendoredLibDir() []const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "third_party/adbc/1.11.0/lib/macos-arm64",
            .x86_64 => "third_party/adbc/1.11.0/lib/macos-x86_64",
            else => "third_party/adbc/1.11.0/lib/macos-arm64",
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "third_party/adbc/1.11.0/lib/linux-arm64",
            .x86_64 => "third_party/adbc/1.11.0/lib/linux-x86_64",
            else => "third_party/adbc/1.11.0/lib/linux-x86_64",
        },
        .windows => "third_party/adbc/1.11.0/lib/windows-x86_64",
        else => "third_party/adbc/1.11.0/lib/macos-arm64",
    };
}

fn managerLibraryFilename() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "libadbc_driver_manager.dylib",
        .linux => "libadbc_driver_manager.so",
        .windows => "adbc_driver_manager.dll",
        else => "libadbc_driver_manager.dylib",
    };
}

fn libraryFilename(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "mysql")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_mysql.dylib",
            .linux => "libadbc_driver_mysql.so",
            .windows => "adbc_driver_mysql.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "sqlite")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_sqlite.dylib",
            .linux => "libadbc_driver_sqlite.so",
            .windows => "adbc_driver_sqlite.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "postgresql")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_postgresql.dylib",
            .linux => "libadbc_driver_postgresql.so",
            .windows => "adbc_driver_postgresql.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "snowflake")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_snowflake.dylib",
            .linux => "libadbc_driver_snowflake.so",
            .windows => "adbc_driver_snowflake.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "flightsql")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_flightsql.dylib",
            .linux => "libadbc_driver_flightsql.so",
            .windows => "adbc_driver_flightsql.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "bigquery")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_bigquery.dylib",
            .linux => "libadbc_driver_bigquery.so",
            .windows => "adbc_driver_bigquery.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "mssql")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_mssql.dylib",
            .linux => "libadbc_driver_mssql.so",
            .windows => "adbc_driver_mssql.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "redshift")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_redshift.dylib",
            .linux => "libadbc_driver_redshift.so",
            .windows => "adbc_driver_redshift.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "trino")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_trino.dylib",
            .linux => "libadbc_driver_trino.so",
            .windows => "adbc_driver_trino.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "databricks")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_databricks.dylib",
            .linux => "libadbc_driver_databricks.so",
            .windows => "adbc_driver_databricks.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "clickhouse")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_clickhouse.dylib",
            .linux => "libadbc_driver_clickhouse.so",
            .windows => "adbc_driver_clickhouse.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "exasol")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_exasol.dylib",
            .linux => "libadbc_driver_exasol.so",
            .windows => "adbc_driver_exasol.dll",
            else => return Error.InvalidArgument,
        };
    }
    if (std.mem.eql(u8, name, "singlestore")) {
        return switch (builtin.os.tag) {
            .macos => "libadbc_driver_singlestore.dylib",
            .linux => "libadbc_driver_singlestore.so",
            .windows => "adbc_driver_singlestore.dll",
            else => return Error.InvalidArgument,
        };
    }
    return Error.InvalidArgument;
}

fn setDatabaseOption(
    allocator: std.mem.Allocator,
    runtime: *const Runtime,
    database: *AdbcDatabase,
    key: []const u8,
    value: []const u8,
    error_info: *AdbcError,
) !void {
    try withSentinel2(allocator, key, value, struct {
        fn apply(runtime_inner: *const Runtime, database_inner: *AdbcDatabase, key_inner: [*:0]const u8, value_inner: [*:0]const u8, error_info_inner: *AdbcError) !void {
            try requireOk(runtime_inner.db_set_option(database_inner, key_inner, value_inner, error_info_inner), error_info_inner);
        }
    }.apply, runtime, database, error_info);
}

fn columnsFromSchema(allocator: std.mem.Allocator, schema: *ArrowSchema) ![]types.ColumnMetadata {
    if (schema.n_children <= 0 or schema.children == null) {
        return allocator.alloc(types.ColumnMetadata, 0);
    }

    const child_count: usize = @intCast(schema.n_children);
    var columns = try allocator.alloc(types.ColumnMetadata, child_count);
    errdefer {
        for (columns) |column| {
            allocator.free(column.name);
        }
        allocator.free(columns);
    }

    for (0..child_count) |index| {
        const child = schema.children[index] orelse return Error.QueryFailed;
        const name = if (child.name) |raw_name| std.mem.span(raw_name) else "";
        const raw_type = rawTypeFromSchema(child);
        columns[index] = .{
            .name = try allocator.dupe(u8, name),
            .raw_type = if (raw_type) |value| try allocator.dupe(u8, value) else null,
            .column_type = mapArrowSchemaToColumnType(child),
            .nullable = (child.flags & arrow_flag_nullable) != 0,
        };
    }

    return columns;
}

fn appendRowsFromArray(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(types.ResultRow),
    schema: *ArrowSchema,
    array: *ArrowArray,
) !void {
    if (array.length <= 0) {
        return;
    }
    if ((array.n_children <= 0 or array.children == null) and array.length > 0) {
        return;
    }
    if (schema.n_children != array.n_children) {
        return Error.QueryFailed;
    }

    const row_count: usize = @intCast(array.length);
    const column_count: usize = if (array.n_children > 0) @intCast(array.n_children) else 0;
    for (0..row_count) |row_index| {
        const values = try allocator.alloc(types.ResultCell, column_count);
        errdefer {
            for (values) |cell| {
                allocator.free(cell.text);
            }
            allocator.free(values);
        }

        for (0..column_count) |column_index| {
            const child_schema = schema.children[column_index] orelse return Error.QueryFailed;
            const child_array = array.children[column_index] orelse return Error.QueryFailed;
            values[column_index] = try cellFromArrow(allocator, child_schema, child_array, row_index);
        }

        try rows.append(allocator, .{ .values = values });
    }
}

fn cellFromArrow(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
) anyerror!types.ResultCell {
    if (isNullAt(array, row_index)) {
        return .{
            .text = try allocator.alloc(u8, 0),
            .is_null = true,
        };
    }

    if (schema.dictionary != null) {
        return cellFromArrowDictionary(allocator, schema, array, row_index);
    }

    const format = if (schema.format) |value| std.mem.span(value) else "";
    return .{
        .text = try extractArrowValueText(allocator, schema, format, array, row_index),
        .is_null = false,
    };
}

fn cellFromArrowDictionary(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
) anyerror!types.ResultCell {
    const dictionary_schema = schema.dictionary orelse return Error.QueryFailed;
    const dictionary_array = array.dictionary orelse return Error.QueryFailed;
    const format = if (schema.format) |value| std.mem.span(value) else "";
    const dictionary_index = try readArrowDictionaryIndex(format, array, row_index);
    if (dictionary_index >= @as(usize, @intCast(dictionary_array.length))) {
        return Error.QueryFailed;
    }
    return cellFromArrow(allocator, dictionary_schema, dictionary_array, dictionary_index);
}

fn readArrowDictionaryIndex(format: []const u8, array: *ArrowArray, row_index: usize) !usize {
    if (format.len == 0) {
        return Error.QueryFailed;
    }

    return switch (format[0]) {
        'c' => readArrowDictionaryIndexValue(i8, array, row_index),
        'C' => readArrowDictionaryIndexValue(u8, array, row_index),
        's' => readArrowDictionaryIndexValue(i16, array, row_index),
        'S' => readArrowDictionaryIndexValue(u16, array, row_index),
        'i' => readArrowDictionaryIndexValue(i32, array, row_index),
        'I' => readArrowDictionaryIndexValue(u32, array, row_index),
        'l' => readArrowDictionaryIndexValue(i64, array, row_index),
        'L' => readArrowDictionaryIndexValue(u64, array, row_index),
        else => Error.QueryFailed,
    };
}

fn readArrowDictionaryIndexValue(
    comptime T: type,
    array: *ArrowArray,
    row_index: usize,
) !usize {
    const value = try readArrowPrimitiveValue(T, array, row_index);
    switch (@typeInfo(T)) {
        .int => if (value < 0) {
            return Error.QueryFailed;
        },
        else => {},
    }
    return @intCast(value);
}

fn readArrowPrimitiveValue(
    comptime T: type,
    array: *ArrowArray,
    row_index: usize,
) !T {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const T = @ptrCast(@alignCast(array.buffers[1].?));
    return values[logical_index];
}

fn isNullAt(array: *ArrowArray, row_index: usize) bool {
    if (array.null_count == 0) {
        return false;
    }
    if (array.buffers == null or array.buffers[0] == null) {
        return false;
    }

    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const bitmap: [*]const u8 = @ptrCast(array.buffers[0].?);
    const byte = bitmap[logical_index / 8];
    const mask: u8 = @as(u8, 1) << @intCast(logical_index % 8);
    return (byte & mask) == 0;
}

fn extractArrowValueText(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len == 0) {
        return allocator.alloc(u8, 0);
    }

    if (try extractOpaqueValueText(allocator, schema, format, array, row_index)) |text| {
        return text;
    }

    if (format[0] == 'v' and format.len >= 2) {
        return switch (format[1]) {
            'u' => formatArrowViewUtf8(allocator, array, row_index),
            'z' => formatArrowViewBinary(allocator, array, row_index),
            else => allocator.alloc(u8, 0),
        };
    }

    if (format[0] == '+' and format.len >= 2) {
        return switch (format[1]) {
            'l' => formatArrowList(allocator, schema, array, row_index, i32),
            'L' => formatArrowList(allocator, schema, array, row_index, i64),
            'v' => if (format.len >= 3) switch (format[2]) {
                'l' => formatArrowListView(allocator, schema, array, row_index, i32),
                'L' => formatArrowListView(allocator, schema, array, row_index, i64),
                else => allocator.alloc(u8, 0),
            } else allocator.alloc(u8, 0),
            'w' => formatArrowFixedSizeList(allocator, schema, format, array, row_index),
            's' => formatArrowStruct(allocator, schema, array, row_index),
            'm' => formatArrowMap(allocator, schema, array, row_index),
            else => allocator.alloc(u8, 0),
        };
    }

    if (format[0] == 't' and format.len >= 2) {
        return switch (format[1]) {
            'd' => formatArrowDate(allocator, format, array, row_index),
            't' => formatArrowTime(allocator, format, array, row_index),
            's' => formatArrowTimestamp(allocator, format, array, row_index),
            'D' => formatArrowDuration(allocator, format, array, row_index),
            'i' => formatArrowInterval(allocator, format, array, row_index),
            else => allocator.alloc(u8, 0),
        };
    }

    return switch (format[0]) {
        'b' => formatArrowBool(allocator, array, row_index),
        'c' => formatArrowInt(allocator, i8, array, row_index),
        'C' => formatArrowUInt(allocator, u8, array, row_index),
        's' => formatArrowInt(allocator, i16, array, row_index),
        'S' => formatArrowUInt(allocator, u16, array, row_index),
        'i' => formatArrowInt(allocator, i32, array, row_index),
        'I' => formatArrowUInt(allocator, u32, array, row_index),
        'l' => formatArrowInt(allocator, i64, array, row_index),
        'L' => formatArrowUInt(allocator, u64, array, row_index),
        'f' => formatArrowFloat32(allocator, array, row_index),
        'g' => formatArrowFloat64(allocator, array, row_index),
        'u' => formatArrowUtf8(allocator, i32, array, row_index),
        'U' => formatArrowUtf8(allocator, i64, array, row_index),
        'z' => formatArrowBinary(allocator, i32, array, row_index),
        'Z' => formatArrowBinary(allocator, i64, array, row_index),
        'w' => formatArrowFixedBinary(allocator, format, array, row_index),
        'd' => formatArrowDecimal(allocator, format, array, row_index),
        'T' => formatArrowInt(allocator, i64, array, row_index),
        else => allocator.alloc(u8, 0),
    };
}

const DecimalFormat = struct {
    scale: usize,
    byte_width: usize,
};

fn formatArrowDecimal(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    const decimal_format = parseArrowDecimalFormat(format) orelse return formatArrowBinaryWord(allocator, 16, array, row_index);
    if (decimal_format.byte_width > 16) {
        return formatArrowBinaryWord(allocator, decimal_format.byte_width, array, row_index);
    }
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }

    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const u8 = @ptrCast(array.buffers[1].?);
    const start = logical_index * decimal_format.byte_width;
    const bytes = values[start .. start + decimal_format.byte_width];
    const value = try decodeSignedLittleEndianDecimal(bytes);
    return formatScaledDecimal(allocator, value, decimal_format.scale);
}

fn parseArrowDecimalFormat(format: []const u8) ?DecimalFormat {
    if (format.len == 0 or format[0] != 'd') return null;
    if (format.len == 1) return .{ .scale = 0, .byte_width = 16 };
    if (format[1] != ':') return null;

    var parts = std.mem.splitScalar(u8, format[2..], ',');
    _ = parts.next() orelse return null;
    const scale_text = parts.next() orelse return null;
    const scale = std.fmt.parseInt(usize, scale_text, 10) catch return null;

    const bit_width = if (parts.next()) |bit_width_text|
        std.fmt.parseInt(usize, bit_width_text, 10) catch return null
    else
        128;

    if (bit_width == 0 or bit_width % 8 != 0) return null;
    return .{ .scale = scale, .byte_width = bit_width / 8 };
}

fn decodeSignedLittleEndianDecimal(bytes: []const u8) !i128 {
    if (bytes.len == 0 or bytes.len > 16) return Error.QueryFailed;

    var bits: u128 = 0;
    for (bytes, 0..) |byte, index| {
        bits |= @as(u128, byte) << @intCast(index * 8);
    }

    const bit_count = bytes.len * 8;
    if (bit_count < 128 and (bytes[bytes.len - 1] & 0x80) != 0) {
        bits |= (~@as(u128, 0)) << @intCast(bit_count);
    }

    return @bitCast(bits);
}

fn formatScaledDecimal(allocator: std.mem.Allocator, value: i128, scale: usize) ![]u8 {
    const bits: u128 = @bitCast(value);
    const negative = value < 0;
    const magnitude: u128 = if (negative) (~bits + 1) else bits;
    const digits = try std.fmt.allocPrint(allocator, "{}", .{magnitude});
    defer allocator.free(digits);

    if (scale == 0) {
        if (!negative) return allocator.dupe(u8, digits);
        return std.fmt.allocPrint(allocator, "-{s}", .{digits});
    }

    const whole_len = if (digits.len > scale) digits.len - scale else 0;
    const whole = if (whole_len == 0) "0" else digits[0..whole_len];
    const fractional = if (whole_len == digits.len) "" else digits[whole_len..];
    const zero_padding_len = if (digits.len >= scale) 0 else scale - digits.len;
    const zero_padding = try allocator.alloc(u8, zero_padding_len);
    defer allocator.free(zero_padding);
    @memset(zero_padding, '0');

    if (!negative) {
        return std.fmt.allocPrint(allocator, "{s}.{s}{s}", .{ whole, zero_padding, fractional });
    }
    return std.fmt.allocPrint(allocator, "-{s}.{s}{s}", .{ whole, zero_padding, fractional });
}

fn formatArrowBool(allocator: std.mem.Allocator, array: *ArrowArray, row_index: usize) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const u8 = @ptrCast(array.buffers[1].?);
    const byte = values[logical_index / 8];
    const mask: u8 = @as(u8, 1) << @intCast(logical_index % 8);
    return allocator.dupe(u8, if ((byte & mask) != 0) "true" else "false");
}

fn formatArrowInt(
    allocator: std.mem.Allocator,
    comptime T: type,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const T = @ptrCast(@alignCast(array.buffers[1].?));
    return std.fmt.allocPrint(allocator, "{}", .{values[logical_index]});
}

fn formatArrowUInt(
    allocator: std.mem.Allocator,
    comptime T: type,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const T = @ptrCast(@alignCast(array.buffers[1].?));
    return std.fmt.allocPrint(allocator, "{}", .{values[logical_index]});
}

fn formatArrowFloat32(allocator: std.mem.Allocator, array: *ArrowArray, row_index: usize) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const f32 = @ptrCast(@alignCast(array.buffers[1].?));
    return std.fmt.allocPrint(allocator, "{d}", .{values[logical_index]});
}

fn formatArrowFloat64(allocator: std.mem.Allocator, array: *ArrowArray, row_index: usize) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const f64 = @ptrCast(@alignCast(array.buffers[1].?));
    return std.fmt.allocPrint(allocator, "{d}", .{values[logical_index]});
}

fn formatArrowUtf8(
    allocator: std.mem.Allocator,
    comptime OffsetType: type,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null or array.buffers[2] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[1].?));
    const values: [*]const u8 = @ptrCast(array.buffers[2].?);
    const start: usize = @intCast(offsets[logical_index]);
    const end: usize = @intCast(offsets[logical_index + 1]);
    return allocator.dupe(u8, values[start..end]);
}

fn formatArrowViewUtf8(allocator: std.mem.Allocator, array: *ArrowArray, row_index: usize) ![]u8 {
    const bytes = try readArrowViewSlice(array, row_index);
    return allocator.dupe(u8, bytes);
}

fn formatArrowViewBinary(allocator: std.mem.Allocator, array: *ArrowArray, row_index: usize) ![]u8 {
    const bytes = try readArrowViewSlice(array, row_index);
    return encodeHexAlloc(allocator, bytes);
}

fn formatArrowBinary(
    allocator: std.mem.Allocator,
    comptime OffsetType: type,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null or array.buffers[2] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[1].?));
    const values: [*]const u8 = @ptrCast(array.buffers[2].?);
    const start: usize = @intCast(offsets[logical_index]);
    const end: usize = @intCast(offsets[logical_index + 1]);
    return encodeHexAlloc(allocator, values[start..end]);
}

fn formatArrowFixedBinary(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const colon_index = std.mem.indexOfScalar(u8, format, ':') orelse return Error.QueryFailed;
    const byte_width = try std.fmt.parseInt(usize, format[colon_index + 1 ..], 10);
    return formatArrowBinaryWord(allocator, byte_width, array, row_index);
}

fn formatArrowBinaryWord(
    allocator: std.mem.Allocator,
    byte_width: usize,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const u8 = @ptrCast(array.buffers[1].?);
    const start = logical_index * byte_width;
    return encodeHexAlloc(allocator, values[start .. start + byte_width]);
}

fn encodeHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = alphabet[byte >> 4];
        encoded[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return encoded;
}

const BinaryView = extern struct {
    size: i32,
    inline_or_ref: [12]u8,
};

const DayTimeInterval = extern struct {
    days: i32,
    milliseconds: i32,
};

const MonthDayNanoInterval = extern struct {
    months: i32,
    days: i32,
    nanoseconds: i64,
};

const seconds_per_day: i64 = 86_400;
const milliseconds_per_day: i64 = seconds_per_day * 1_000;
const microseconds_per_day: i64 = seconds_per_day * 1_000_000;
const nanoseconds_per_day: i64 = seconds_per_day * 1_000_000_000;
const nanoseconds_per_microsecond: i64 = 1_000;

fn readArrowUtf8Slice(
    comptime OffsetType: type,
    array: *ArrowArray,
    row_index: usize,
) ![]const u8 {
    if (array.buffers == null or array.buffers[1] == null or array.buffers[2] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[1].?));
    const values: [*]const u8 = @ptrCast(array.buffers[2].?);
    const start: usize = @intCast(offsets[logical_index]);
    const end: usize = @intCast(offsets[logical_index + 1]);
    return values[start..end];
}

fn readArrowBinarySlice(
    comptime OffsetType: type,
    array: *ArrowArray,
    row_index: usize,
) ![]const u8 {
    return readArrowUtf8Slice(OffsetType, array, row_index);
}

fn readArrowFixedBinarySlice(format: []const u8, array: *ArrowArray, row_index: usize) ![]const u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const colon_index = std.mem.indexOfScalar(u8, format, ':') orelse return Error.QueryFailed;
    const byte_width = try std.fmt.parseInt(usize, format[colon_index + 1 ..], 10);
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const values: [*]const u8 = @ptrCast(array.buffers[1].?);
    const start = logical_index * byte_width;
    return values[start .. start + byte_width];
}

fn readArrowViewSlice(array: *ArrowArray, row_index: usize) ![]const u8 {
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }

    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const views: [*]const BinaryView = @ptrCast(@alignCast(array.buffers[1].?));
    const view = views[logical_index];
    const size: usize = @intCast(view.size);
    if (size <= 12) {
        return view.inline_or_ref[0..size];
    }

    if (array.n_buffers < 4) {
        return Error.QueryFailed;
    }

    const buffer_index = std.mem.readInt(i32, view.inline_or_ref[4..8], builtin.cpu.arch.endian());
    const offset = std.mem.readInt(i32, view.inline_or_ref[8..12], builtin.cpu.arch.endian());
    if (buffer_index < 0 or offset < 0) {
        return Error.QueryFailed;
    }

    const data_buffer_index: usize = 3 + @as(usize, @intCast(buffer_index));
    if (data_buffer_index >= @as(usize, @intCast(array.n_buffers)) or array.buffers[data_buffer_index] == null) {
        return Error.QueryFailed;
    }

    const values: [*]const u8 = @ptrCast(array.buffers[data_buffer_index].?);
    const start: usize = @intCast(offset);
    return values[start .. start + size];
}

fn readArrowValueBytesForOpaque(format: []const u8, array: *ArrowArray, row_index: usize) !?[]const u8 {
    if (format.len == 0) return null;

    if (format[0] == 'v' and format.len >= 2) {
        return switch (format[1]) {
            'u', 'z' => try readArrowViewSlice(array, row_index),
            else => null,
        };
    }

    return switch (format[0]) {
        'u' => try readArrowUtf8Slice(i32, array, row_index),
        'U' => try readArrowUtf8Slice(i64, array, row_index),
        'z' => try readArrowBinarySlice(i32, array, row_index),
        'Z' => try readArrowBinarySlice(i64, array, row_index),
        'w' => try readArrowFixedBinarySlice(format, array, row_index),
        else => null,
    };
}

fn formatArrowDate(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len < 3) return Error.QueryFailed;
    return switch (format[2]) {
        'D' => formatDaysSinceEpoch(allocator, try readArrowPrimitiveValue(i32, array, row_index)),
        'm' => formatDaysSinceEpoch(allocator, @divFloor(try readArrowPrimitiveValue(i64, array, row_index), milliseconds_per_day)),
        else => allocator.alloc(u8, 0),
    };
}

fn formatArrowTime(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len < 3) return Error.QueryFailed;
    return switch (format[2]) {
        's' => formatTimeOfDay(allocator, try readArrowPrimitiveValue(i32, array, row_index), 0),
        'm' => formatTimeOfDay(allocator, try readArrowPrimitiveValue(i32, array, row_index), 3),
        'u' => formatTimeOfDay(allocator, try readArrowPrimitiveValue(i64, array, row_index), 6),
        'n' => formatTimeOfDay(allocator, try readArrowPrimitiveValue(i64, array, row_index), 9),
        else => allocator.alloc(u8, 0),
    };
}

fn formatArrowTimestamp(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len < 3) return Error.QueryFailed;
    const raw_value = try readArrowPrimitiveValue(i64, array, row_index);
    return formatTimestampValue(allocator, raw_value, format[2]);
}

fn formatArrowDuration(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len < 3) return Error.QueryFailed;
    const raw_value = try readArrowPrimitiveValue(i64, array, row_index);
    return switch (format[2]) {
        's' => std.fmt.allocPrint(allocator, "PT{}S", .{raw_value}),
        'm' => formatDayTimeIntervalComponents(allocator, 0, raw_value),
        'u' => formatMonthDayNanoIntervalComponents(allocator, 0, 0, raw_value * nanoseconds_per_microsecond),
        'n' => formatMonthDayNanoIntervalComponents(allocator, 0, 0, raw_value),
        else => allocator.alloc(u8, 0),
    };
}

fn formatArrowInterval(
    allocator: std.mem.Allocator,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len < 3) return Error.QueryFailed;
    return switch (format[2]) {
        'M' => formatMonthDayNanoIntervalComponents(allocator, try readArrowPrimitiveValue(i32, array, row_index), 0, 0),
        'D' => {
            const interval_value = try readArrowPrimitiveValue(DayTimeInterval, array, row_index);
            return formatDayTimeIntervalComponents(allocator, interval_value.days, interval_value.milliseconds);
        },
        'n' => {
            const interval_value = try readArrowPrimitiveValue(MonthDayNanoInterval, array, row_index);
            return formatMonthDayNanoIntervalComponents(allocator, interval_value.months, interval_value.days, interval_value.nanoseconds);
        },
        else => allocator.alloc(u8, 0),
    };
}

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const shifted = days_since_epoch + 719_468;
    const era = @divFloor(if (shifted >= 0) shifted else shifted - 146_096, 146_097);
    const day_of_era = shifted - era * 146_097;
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1_460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i64, 3) else @as(i64, -9));
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn formatDaysSinceEpoch(allocator: std.mem.Allocator, days_since_epoch: anytype) ![]u8 {
    const civil = civilFromDays(@as(i64, @intCast(days_since_epoch)));
    return formatIsoDate(allocator, civil.year, civil.month, civil.day);
}

fn formatIsoDate(allocator: std.mem.Allocator, year: i64, month: i64, day: i64) ![]u8 {
    const month_value: u64 = @intCast(month);
    const day_value: u64 = @intCast(day);
    if (year < 0) {
        return std.fmt.allocPrint(allocator, "-{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(-year)), month_value, day_value });
    }
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), month_value, day_value });
}

fn formatTimeOfDay(allocator: std.mem.Allocator, raw_value: anytype, fraction_digits: usize) ![]u8 {
    const value: i64 = @intCast(raw_value);
    const scale: i64 = switch (fraction_digits) {
        0 => 1,
        3 => 1_000,
        6 => 1_000_000,
        9 => 1_000_000_000,
        else => return Error.QueryFailed,
    };
    const total_seconds = @divFloor(value, scale);
    const fractional = @mod(value, scale);
    const hours = @divFloor(total_seconds, 3_600);
    const minutes = @mod(@divFloor(total_seconds, 60), 60);
    const seconds = @mod(total_seconds, 60);
    const hour_value: u64 = @intCast(hours);
    const minute_value: u64 = @intCast(minutes);
    const second_value: u64 = @intCast(seconds);
    if (fraction_digits == 0) {
        return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour_value, minute_value, second_value });
    }
    const fraction_text = switch (fraction_digits) {
        3 => try std.fmt.allocPrint(allocator, "{d:0>3}", .{@as(u64, @intCast(fractional))}),
        6 => try std.fmt.allocPrint(allocator, "{d:0>6}", .{@as(u64, @intCast(fractional))}),
        9 => try std.fmt.allocPrint(allocator, "{d:0>9}", .{@as(u64, @intCast(fractional))}),
        else => return Error.QueryFailed,
    };
    defer allocator.free(fraction_text);
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{s}", .{ hour_value, minute_value, second_value, fraction_text });
}

fn formatTimestampValue(allocator: std.mem.Allocator, raw_value: i64, unit: u8) ![]u8 {
    const units_per_second: i64 = switch (unit) {
        's' => 1,
        'm' => 1_000,
        'u' => 1_000_000,
        'n' => 1_000_000_000,
        else => return Error.QueryFailed,
    };
    const units_per_day = units_per_second * seconds_per_day;
    const days_since_epoch = @divFloor(raw_value, units_per_day);
    const day_units = @mod(raw_value, units_per_day);
    const civil = civilFromDays(days_since_epoch);
    const time_text = switch (unit) {
        's' => try formatTimeOfDay(allocator, day_units, 0),
        'm' => try formatTimeOfDay(allocator, day_units, 3),
        'u' => try formatTimeOfDay(allocator, day_units, 6),
        'n' => try formatTimeOfDay(allocator, day_units, 9),
        else => unreachable,
    };
    defer allocator.free(time_text);
    const date_text = try formatIsoDate(allocator, civil.year, civil.month, civil.day);
    defer allocator.free(date_text);
    return std.fmt.allocPrint(allocator, "{s}T{s}", .{ date_text, time_text });
}

fn formatDayTimeIntervalComponents(allocator: std.mem.Allocator, days: anytype, milliseconds: anytype) ![]u8 {
    const day_value: i64 = @intCast(days);
    const millisecond_value: i64 = @intCast(milliseconds);
    const time_text = try formatTimeOfDay(allocator, millisecond_value, 3);
    defer allocator.free(time_text);
    return std.fmt.allocPrint(allocator, "P{}DT{s}", .{ day_value, time_text });
}

fn formatMonthDayNanoIntervalComponents(allocator: std.mem.Allocator, months: anytype, days: anytype, nanoseconds: anytype) ![]u8 {
    const month_value: i64 = @intCast(months);
    const day_value: i64 = @intCast(days);
    const nanosecond_value: i64 = @intCast(nanoseconds);
    const time_text = try formatTimeOfDay(allocator, nanosecond_value, 9);
    defer allocator.free(time_text);
    return std.fmt.allocPrint(allocator, "P{}M{}DT{s}", .{ month_value, day_value, time_text });
}

fn formatArrowList(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
    comptime OffsetType: type,
) ![]u8 {
    if (schema.n_children != 1 or schema.children == null or array.n_children != 1 or array.children == null) {
        return Error.QueryFailed;
    }
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[1].?));
    const start: usize = @intCast(offsets[logical_index]);
    const end: usize = @intCast(offsets[logical_index + 1]);
    return formatArrowSequenceJson(
        allocator,
        schema.children[0] orelse return Error.QueryFailed,
        array.children[0] orelse return Error.QueryFailed,
        start,
        end,
    );
}

fn formatArrowListView(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
    comptime OffsetType: type,
) ![]u8 {
    if (schema.n_children != 1 or schema.children == null or array.n_children != 1 or array.children == null) {
        return Error.QueryFailed;
    }
    if (array.buffers == null or array.buffers[1] == null or array.buffers[2] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[1].?));
    const sizes: [*]const OffsetType = @ptrCast(@alignCast(array.buffers[2].?));
    const start: usize = @intCast(offsets[logical_index]);
    const size: usize = @intCast(sizes[logical_index]);
    return formatArrowSequenceJson(
        allocator,
        schema.children[0] orelse return Error.QueryFailed,
        array.children[0] orelse return Error.QueryFailed,
        start,
        start + size,
    );
}

fn formatArrowFixedSizeList(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (schema.n_children != 1 or schema.children == null or array.n_children != 1 or array.children == null) {
        return Error.QueryFailed;
    }
    const colon_index = std.mem.indexOfScalar(u8, format, ':') orelse return Error.QueryFailed;
    const item_count = try std.fmt.parseInt(usize, format[colon_index + 1 ..], 10);
    const start = row_index * item_count;
    return formatArrowSequenceJson(
        allocator,
        schema.children[0] orelse return Error.QueryFailed,
        array.children[0] orelse return Error.QueryFailed,
        start,
        start + item_count,
    );
}

fn formatArrowStruct(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (schema.n_children != array.n_children or schema.children == null or array.children == null) {
        return Error.QueryFailed;
    }
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try builder.append(allocator, '{');
    const child_count: usize = @intCast(schema.n_children);
    for (0..child_count) |index| {
        if (index != 0) try builder.appendSlice(allocator, ",");
        const child_schema = schema.children[index] orelse return Error.QueryFailed;
        const child_array = array.children[index] orelse return Error.QueryFailed;
        try appendJsonQuoted(allocator, &builder, if (child_schema.name) |value| std.mem.span(value) else "");
        try builder.appendSlice(allocator, ":");
        try appendArrowJsonValue(allocator, &builder, child_schema, child_array, row_index);
    }
    try builder.append(allocator, '}');
    return builder.toOwnedSlice(allocator);
}

fn formatArrowMap(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (schema.n_children != 1 or schema.children == null or array.n_children != 1 or array.children == null) {
        return Error.QueryFailed;
    }
    if (array.buffers == null or array.buffers[1] == null) {
        return Error.QueryFailed;
    }
    const logical_index = row_index + @as(usize, @intCast(array.offset));
    const offsets: [*]const i32 = @ptrCast(@alignCast(array.buffers[1].?));
    const start: usize = @intCast(offsets[logical_index]);
    const end: usize = @intCast(offsets[logical_index + 1]);
    return formatArrowSequenceJson(
        allocator,
        schema.children[0] orelse return Error.QueryFailed,
        array.children[0] orelse return Error.QueryFailed,
        start,
        end,
    );
}

fn formatArrowSequenceJson(
    allocator: std.mem.Allocator,
    child_schema: *ArrowSchema,
    child_array: *ArrowArray,
    start: usize,
    end: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try builder.append(allocator, '[');
    var index = start;
    while (index < end) : (index += 1) {
        if (index != start) try builder.appendSlice(allocator, ",");
        try appendArrowJsonValue(allocator, &builder, child_schema, child_array, index);
    }
    try builder.append(allocator, ']');
    return builder.toOwnedSlice(allocator);
}

fn appendArrowJsonValue(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    schema: *ArrowSchema,
    array: *ArrowArray,
    row_index: usize,
) !void {
    const cell = try cellFromArrow(allocator, schema, array, row_index);
    defer allocator.free(cell.text);

    if (cell.is_null) {
        try builder.appendSlice(allocator, "null");
        return;
    }

    switch (mapArrowSchemaToColumnType(schema)) {
        .boolean,
        .int8,
        .uint8,
        .int16,
        .uint16,
        .int32,
        .uint32,
        .int64,
        .uint64,
        .float16,
        .float32,
        .float64,
        .decimal,
        .json,
        .array,
        .map,
        .struct_,
        => try builder.appendSlice(allocator, cell.text),
        else => try appendJsonQuoted(allocator, builder, cell.text),
    }
}

fn appendJsonQuoted(allocator: std.mem.Allocator, builder: *std.ArrayList(u8), value: []const u8) !void {
    try builder.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try builder.appendSlice(allocator, "\\\""),
            '\\' => try builder.appendSlice(allocator, "\\\\"),
            '\n' => try builder.appendSlice(allocator, "\\n"),
            '\r' => try builder.appendSlice(allocator, "\\r"),
            '\t' => try builder.appendSlice(allocator, "\\t"),
            else => {
                if (byte < 0x20) {
                    var scratch: [6]u8 = undefined;
                    const encoded = try std.fmt.bufPrint(&scratch, "\\u00{x:0>2}", .{byte});
                    try builder.appendSlice(allocator, encoded);
                } else {
                    try builder.append(allocator, byte);
                }
            },
        }
    }
    try builder.append(allocator, '"');
}

fn extractOpaqueValueText(
    allocator: std.mem.Allocator,
    schema: *ArrowSchema,
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) !?[]u8 {
    const typname = postgresTypeName(schema.metadata) orelse return null;
    const bytes = try readArrowValueBytesForOpaque(format, array, row_index) orelse return null;

    if (std.mem.eql(u8, typname, "uuid")) {
        return try formatUuidBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "xml")) {
        return try allocator.dupe(u8, bytes);
    }
    if (std.mem.eql(u8, typname, "inet") or std.mem.eql(u8, typname, "cidr")) {
        return try formatPostgresInetBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "macaddr") or std.mem.eql(u8, typname, "macaddr8")) {
        return try formatMacAddressBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "tsvector")) {
        return try formatPostgresTsVectorBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "tsquery")) {
        return try formatPostgresTsQueryBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "point")) {
        return try formatPostgresPointBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "box")) {
        return try formatPostgresBoxBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "pg_lsn")) {
        return try formatPostgresLsnBytes(allocator, bytes);
    }
    if (std.mem.eql(u8, typname, "tid")) {
        return try formatPostgresTidBytes(allocator, bytes);
    }
    if (isPostgresOidLikeType(typname)) {
        return try formatPostgresOidLikeBytes(allocator, bytes);
    }
    return null;
}

fn formatUuidBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 16) return Error.QueryFailed;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] },
    );
}

fn formatPostgresInetBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 4) return Error.QueryFailed;
    const family = bytes[0];
    const mask = bytes[1];
    const is_cidr = bytes[2] != 0;
    const size = bytes[3];
    if (bytes.len != 4 + size) return Error.QueryFailed;

    if (family == 2 and size == 4) {
        const base = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{ bytes[4], bytes[5], bytes[6], bytes[7] });
        defer allocator.free(base);
        if (is_cidr or mask != 32) return std.fmt.allocPrint(allocator, "{s}/{}", .{ base, mask });
        return allocator.dupe(u8, base);
    }

    if (family == 3 and size == 16) {
        const base = try std.fmt.allocPrint(
            allocator,
            "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}",
            .{ bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15], bytes[16], bytes[17], bytes[18], bytes[19] },
        );
        defer allocator.free(base);
        if (is_cidr or mask != 128) return std.fmt.allocPrint(allocator, "{s}/{}", .{ base, mask });
        return allocator.dupe(u8, base);
    }

    return Error.QueryFailed;
}

fn formatMacAddressBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 6 and bytes.len != 8) return Error.QueryFailed;
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    for (bytes, 0..) |byte, index| {
        if (index != 0) try builder.append(allocator, ':');
        const encoded = try std.fmt.allocPrint(allocator, "{x:0>2}", .{byte});
        defer allocator.free(encoded);
        try builder.appendSlice(allocator, encoded);
    }
    return builder.toOwnedSlice(allocator);
}

const PostgresTsQueryOperatorKind = enum(u8) {
    not_ = 1,
    and_ = 2,
    or_ = 3,
    phrase = 4,
};

const PostgresTsQueryValue = struct {
    operand: []const u8,
    weight: u8,
    prefix: bool,
};

const PostgresTsQueryOperator = struct {
    kind: PostgresTsQueryOperatorKind,
    distance: u16 = 1,
};

const PostgresTsQueryItem = union(enum) {
    value: PostgresTsQueryValue,
    op: PostgresTsQueryOperator,
};

const RenderedPostgresTsQuery = struct {
    text: []u8,
    next_index: usize,
    precedence: u8,
};

fn formatPostgresTsVectorBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var offset: usize = 0;
    const lexeme_count = try readPostgresU32(bytes, &offset);

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    var writer = builder.writer(allocator);

    var lexeme_index: usize = 0;
    while (lexeme_index < lexeme_count) : (lexeme_index += 1) {
        if (lexeme_index != 0) try builder.append(allocator, ' ');

        const lexeme = try readPostgresCString(bytes, &offset);
        const positions_count = @as(usize, try readPostgresU16(bytes, &offset));

        try appendPostgresQuotedLexeme(allocator, &builder, lexeme);
        if (positions_count == 0) continue;

        try builder.append(allocator, ':');
        var position_index: usize = 0;
        while (position_index < positions_count) : (position_index += 1) {
            if (position_index != 0) try builder.append(allocator, ',');

            const raw_position = try readPostgresU16(bytes, &offset);
            try writer.print("{}", .{raw_position & 0x3fff});

            const weight = raw_position >> 14;
            if (weight != 0) {
                try builder.append(allocator, 'D' - @as(u8, @intCast(weight)));
            }
        }
    }

    if (offset != bytes.len) return Error.QueryFailed;
    return builder.toOwnedSlice(allocator);
}

fn formatPostgresTsQueryBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var offset: usize = 0;
    const item_count = @as(usize, try readPostgresU32(bytes, &offset));

    var items = std.ArrayList(PostgresTsQueryItem).empty;
    defer items.deinit(allocator);
    try items.ensureTotalCapacity(allocator, item_count);

    var item_index: usize = 0;
    while (item_index < item_count) : (item_index += 1) {
        const item_type = try readPostgresU8(bytes, &offset);
        switch (item_type) {
            1 => {
                const weight = try readPostgresU8(bytes, &offset);
                const prefix = (try readPostgresU8(bytes, &offset)) != 0;
                const operand = try readPostgresCString(bytes, &offset);
                items.appendAssumeCapacity(.{ .value = .{
                    .operand = operand,
                    .weight = weight,
                    .prefix = prefix,
                } });
            },
            2 => {
                const operator_kind = std.meta.intToEnum(PostgresTsQueryOperatorKind, try readPostgresU8(bytes, &offset)) catch return Error.QueryFailed;
                const distance: u16 = if (operator_kind == .phrase) try readPostgresU16(bytes, &offset) else 1;
                items.appendAssumeCapacity(.{ .op = .{
                    .kind = operator_kind,
                    .distance = distance,
                } });
            },
            else => return Error.QueryFailed,
        }
    }

    if (offset != bytes.len) return Error.QueryFailed;

    const rendered = try renderPostgresTsQuery(allocator, items.items, 0);
    if (rendered.next_index != items.items.len) {
        allocator.free(rendered.text);
        return Error.QueryFailed;
    }
    return rendered.text;
}

fn renderPostgresTsQuery(
    allocator: std.mem.Allocator,
    items: []const PostgresTsQueryItem,
    index: usize,
) !RenderedPostgresTsQuery {
    if (index >= items.len) return Error.QueryFailed;

    return switch (items[index]) {
        .value => |value| .{
            .text = try formatPostgresTsQueryValue(allocator, value),
            .next_index = index + 1,
            .precedence = 5,
        },
        .op => |operator| switch (operator.kind) {
            .not_ => {
                const child = try renderPostgresTsQuery(allocator, items, index + 1);
                defer allocator.free(child.text);

                var builder = std.ArrayList(u8).empty;
                defer builder.deinit(allocator);

                try builder.append(allocator, '!');
                if (child.precedence < 4) try builder.append(allocator, '(');
                try builder.appendSlice(allocator, child.text);
                if (child.precedence < 4) try builder.append(allocator, ')');

                return .{
                    .text = try builder.toOwnedSlice(allocator),
                    .next_index = child.next_index,
                    .precedence = 4,
                };
            },
            .and_, .or_, .phrase => {
                const right = try renderPostgresTsQuery(allocator, items, index + 1);
                defer allocator.free(right.text);
                const left = try renderPostgresTsQuery(allocator, items, right.next_index);
                defer allocator.free(left.text);

                const precedence: u8 = switch (operator.kind) {
                    .or_ => 1,
                    .and_ => 2,
                    .phrase => 3,
                    else => unreachable,
                };
                const operator_text = switch (operator.kind) {
                    .or_ => " | ",
                    .and_ => " & ",
                    .phrase => if (operator.distance == 1)
                        " <-> "
                    else
                        try std.fmt.allocPrint(allocator, " <{}> ", .{operator.distance}),
                    else => unreachable,
                };
                defer if (operator.kind == .phrase and operator.distance != 1) allocator.free(operator_text);

                var builder = std.ArrayList(u8).empty;
                defer builder.deinit(allocator);

                if (left.precedence < precedence) try builder.append(allocator, '(');
                try builder.appendSlice(allocator, left.text);
                if (left.precedence < precedence) try builder.append(allocator, ')');

                try builder.appendSlice(allocator, operator_text);

                if (right.precedence < precedence) try builder.append(allocator, '(');
                try builder.appendSlice(allocator, right.text);
                if (right.precedence < precedence) try builder.append(allocator, ')');

                return .{
                    .text = try builder.toOwnedSlice(allocator),
                    .next_index = left.next_index,
                    .precedence = precedence,
                };
            },
        },
    };
}

fn formatPostgresTsQueryValue(allocator: std.mem.Allocator, value: PostgresTsQueryValue) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try appendPostgresQuotedLexeme(allocator, &builder, value.operand);
    if (value.weight != 0 or value.prefix) {
        try builder.append(allocator, ':');
        if ((value.weight & 0x08) != 0) try builder.append(allocator, 'A');
        if ((value.weight & 0x04) != 0) try builder.append(allocator, 'B');
        if ((value.weight & 0x02) != 0) try builder.append(allocator, 'C');
        if ((value.weight & 0x01) != 0) try builder.append(allocator, 'D');
        if (value.prefix) try builder.append(allocator, '*');
    }

    return builder.toOwnedSlice(allocator);
}

fn appendPostgresQuotedLexeme(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    lexeme: []const u8,
) !void {
    try builder.append(allocator, '\'');
    for (lexeme) |character| {
        if (character == '\'' or character == '\\') {
            try builder.append(allocator, character);
        }
        try builder.append(allocator, character);
    }
    try builder.append(allocator, '\'');
}

fn formatPostgresPointBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 16) return Error.QueryFailed;
    const x = try readPostgresFloat64(bytes, 0);
    const y = try readPostgresFloat64(bytes, 8);
    return std.fmt.allocPrint(allocator, "({d},{d})", .{ x, y });
}

fn formatPostgresBoxBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 32) return Error.QueryFailed;
    const high_x = try readPostgresFloat64(bytes, 0);
    const high_y = try readPostgresFloat64(bytes, 8);
    const low_x = try readPostgresFloat64(bytes, 16);
    const low_y = try readPostgresFloat64(bytes, 24);
    return std.fmt.allocPrint(allocator, "({d},{d}),({d},{d})", .{ high_x, high_y, low_x, low_y });
}

fn readPostgresU8(bytes: []const u8, offset: *usize) !u8 {
    if (bytes.len - offset.* < 1) return Error.QueryFailed;
    const value = bytes[offset.*];
    offset.* += 1;
    return value;
}

fn readPostgresU16(bytes: []const u8, offset: *usize) !u16 {
    if (bytes.len - offset.* < 2) return Error.QueryFailed;
    const value = std.mem.readInt(u16, @ptrCast(bytes[offset.* .. offset.* + 2]), .big);
    offset.* += 2;
    return value;
}

fn readPostgresU32(bytes: []const u8, offset: *usize) !u32 {
    if (bytes.len - offset.* < 4) return Error.QueryFailed;
    const value = std.mem.readInt(u32, @ptrCast(bytes[offset.* .. offset.* + 4]), .big);
    offset.* += 4;
    return value;
}

fn readPostgresCString(bytes: []const u8, offset: *usize) ![]const u8 {
    if (offset.* > bytes.len) return Error.QueryFailed;
    const remaining = bytes[offset.*..];
    const terminator_index = std.mem.indexOfScalar(u8, remaining, 0) orelse return Error.QueryFailed;
    const text = remaining[0..terminator_index];
    offset.* += terminator_index + 1;
    return text;
}

fn readPostgresFloat64(bytes: []const u8, start: usize) !f64 {
    if (bytes.len - start < 8) return Error.QueryFailed;
    const bits = std.mem.readInt(u64, @ptrCast(bytes[start .. start + 8]), .big);
    return @bitCast(bits);
}

fn formatPostgresLsnBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 8) return Error.QueryFailed;
    const value = std.mem.readInt(u64, @ptrCast(bytes[0..8]), .big);
    return std.fmt.allocPrint(allocator, "{X}/{X}", .{ value >> 32, value & 0xffff_ffff });
}

fn formatPostgresTidBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 6) return Error.QueryFailed;
    const block = std.mem.readInt(u32, @ptrCast(bytes[0..4]), .big);
    const offset = std.mem.readInt(u16, @ptrCast(bytes[4..6]), .big);
    return std.fmt.allocPrint(allocator, "({},{})", .{ block, offset });
}

fn formatPostgresOidLikeBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len != 4) return Error.QueryFailed;
    const value = std.mem.readInt(u32, @ptrCast(bytes[0..4]), .big);
    return std.fmt.allocPrint(allocator, "{}", .{value});
}

fn isPostgresOidLikeType(typname: []const u8) bool {
    return std.mem.eql(u8, typname, "oid") or
        std.mem.eql(u8, typname, "regclass") or
        std.mem.eql(u8, typname, "regcollation") or
        std.mem.eql(u8, typname, "regconfig") or
        std.mem.eql(u8, typname, "regdictionary") or
        std.mem.eql(u8, typname, "regnamespace") or
        std.mem.eql(u8, typname, "regoper") or
        std.mem.eql(u8, typname, "regoperator") or
        std.mem.eql(u8, typname, "regproc") or
        std.mem.eql(u8, typname, "regprocedure") or
        std.mem.eql(u8, typname, "regrole") or
        std.mem.eql(u8, typname, "regtype");
}

fn isUnsupportedPostgresSemanticType(typname: []const u8) bool {
    return std.mem.eql(u8, typname, "xml") or
        std.mem.eql(u8, typname, "inet") or
        std.mem.eql(u8, typname, "cidr") or
        std.mem.eql(u8, typname, "macaddr") or
        std.mem.eql(u8, typname, "macaddr8") or
        std.mem.eql(u8, typname, "tsvector") or
        std.mem.eql(u8, typname, "tsquery") or
        std.mem.eql(u8, typname, "point") or
        std.mem.eql(u8, typname, "box") or
        std.mem.eql(u8, typname, "pg_lsn") or
        std.mem.eql(u8, typname, "tid");
}

fn rawTypeFromSchema(schema: *ArrowSchema) ?[]const u8 {
    return postgresTypeName(schema.metadata);
}

fn postgresTypeName(metadata: ?[*:0]const u8) ?[]const u8 {
    return arrowMetadataValue(metadata, postgres_typname_key);
}

fn arrowExtensionName(metadata: ?[*:0]const u8) ?[]const u8 {
    return arrowMetadataValue(metadata, arrow_extension_name_key);
}

fn arrowMetadataValue(metadata: ?[*:0]const u8, wanted_key: []const u8) ?[]const u8 {
    const metadata_ptr = metadata orelse return null;
    const bytes: [*]const u8 = @ptrCast(metadata_ptr);
    var offset: usize = 0;
    const pair_count = readArrowMetadataI32(bytes, &offset) orelse return null;
    if (pair_count < 0) return null;

    var pair_index: i32 = 0;
    while (pair_index < pair_count) : (pair_index += 1) {
        const key_length = readArrowMetadataI32(bytes, &offset) orelse return null;
        if (key_length < 0) return null;
        const key_len: usize = @intCast(key_length);
        const key = bytes[offset .. offset + key_len];
        offset += key_len;

        const value_length = readArrowMetadataI32(bytes, &offset) orelse return null;
        if (value_length < 0) return null;
        const value_len: usize = @intCast(value_length);
        const value = bytes[offset .. offset + value_len];
        offset += value_len;

        if (std.mem.eql(u8, key, wanted_key)) return value;
    }
    return null;
}
fn mapArrowSchemaToColumnType(schema: *ArrowSchema) types.ColumnType {
    if (schema.dictionary) |dictionary| {
        return mapArrowSchemaToColumnType(dictionary);
    }

    if (arrowExtensionName(schema.metadata)) |extension_name| {
        if (std.mem.eql(u8, extension_name, "arrow.json")) return .json;
        if (std.mem.eql(u8, extension_name, "arrow.uuid")) return .uuid;
    }

    if (postgresTypeName(schema.metadata)) |typname| {
        if (std.mem.eql(u8, typname, "date")) return .date;
        if (std.mem.eql(u8, typname, "time") or std.mem.eql(u8, typname, "timetz")) return .time;
        if (std.mem.eql(u8, typname, "interval")) return .interval;
        if (std.mem.eql(u8, typname, "uuid")) return .uuid;
        if (isUnsupportedPostgresSemanticType(typname)) return .unknown;
        if (std.mem.eql(u8, typname, "json") or std.mem.eql(u8, typname, "jsonb") or std.mem.eql(u8, typname, "jsonpath")) return .json;
        if (typname.len > 0 and (typname[0] == '_' or std.mem.endsWith(u8, typname, "[]"))) return .array;
        if (isPostgresOidLikeType(typname)) return mapArrowFormatToColumnType(if (schema.format) |fmt| std.mem.span(fmt) else "");
    }

    return mapArrowFormatToColumnType(if (schema.format) |fmt| std.mem.span(fmt) else "");
}

fn readArrowMetadataI32(bytes: [*]const u8, offset: *usize) ?i32 {
    const start = offset.*;
    const value_bytes: *const [@sizeOf(i32)]u8 = @ptrCast(bytes + start);
    const value = std.mem.readInt(i32, value_bytes, builtin.cpu.arch.endian());
    offset.* = start + @sizeOf(i32);
    return value;
}

fn mapArrowFormatToColumnType(format: []const u8) types.ColumnType {
    if (format.len == 0) return .unknown;
    if (format[0] == '+') {
        if (format.len < 2) return .unknown;
        return switch (format[1]) {
            'l', 'L', 'w' => .array,
            'v' => if (format.len >= 3) switch (format[2]) {
                'l', 'L' => .array,
                else => .unknown,
            } else .unknown,
            's' => .struct_,
            'm' => .map,
            else => .unknown,
        };
    }
    if (format[0] == 'v' and format.len >= 2) {
        return switch (format[1]) {
            'u' => .text,
            'z' => .binary,
            else => .unknown,
        };
    }
    if (format[0] == 't' and format.len >= 2) {
        return switch (format[1]) {
            'd' => .date,
            't' => .time,
            's' => .timestamp,
            'D' => .duration,
            'i' => .interval,
            else => .unknown,
        };
    }
    return switch (format[0]) {
        'b' => .boolean,
        'c' => .int8,
        'C' => .uint8,
        's' => .int16,
        'S' => .uint16,
        'i' => .int32,
        'I' => .uint32,
        'l' => .int64,
        'L' => .uint64,
        'e' => .float16,
        'f' => .float32,
        'g' => .float64,
        'u', 'U' => .text,
        'z', 'Z', 'w' => .binary,
        'd' => .decimal,
        'T' => .timestamp,
        else => .unknown,
    };
}

test "adbc backend normalizes dictionary encoded utf8 columns" {
    var dictionary_schema = ArrowSchema{
        .format = "u",
    };
    var child_schema = ArrowSchema{
        .format = "i",
        .name = "status",
        .dictionary = &dictionary_schema,
    };
    var children = [_]?*ArrowSchema{&child_schema};
    var root_schema = ArrowSchema{
        .n_children = 1,
        .children = @ptrCast(&children[0]),
    };

    const columns = try columnsFromSchema(std.testing.allocator, &root_schema);
    defer freeColumns(std.testing.allocator, columns);

    try std.testing.expectEqual(@as(usize, 1), columns.len);
    try std.testing.expectEqualStrings("status", columns[0].name);
    try std.testing.expect(columns[0].raw_type == null);
    try std.testing.expectEqual(types.ColumnType.text, columns[0].column_type);
}

test "adbc backend reads dictionary encoded utf8 cell values" {
    var dictionary_schema = ArrowSchema{
        .format = "u",
    };
    var index_schema = ArrowSchema{
        .format = "i",
        .dictionary = &dictionary_schema,
    };

    var dictionary_offsets = [_]i32{ 0, 5, 9 };
    var dictionary_values = [_]u8{ 'a', 'l', 'p', 'h', 'a', 'b', 'e', 't', 'a' };
    var dictionary_buffers = [_]?*const anyopaque{
        null,
        @ptrCast(&dictionary_offsets[0]),
        @ptrCast(&dictionary_values[0]),
    };
    var dictionary_array = ArrowArray{
        .length = 2,
        .n_buffers = 3,
        .buffers = @ptrCast(&dictionary_buffers[0]),
    };

    var indices = [_]i32{ 0, 1 };
    var index_buffers = [_]?*const anyopaque{
        null,
        @ptrCast(&indices[0]),
    };
    var index_array = ArrowArray{
        .length = 2,
        .n_buffers = 2,
        .buffers = @ptrCast(&index_buffers[0]),
        .dictionary = &dictionary_array,
    };

    const first = try cellFromArrow(std.testing.allocator, &index_schema, &index_array, 0);
    defer std.testing.allocator.free(first.text);
    try std.testing.expectEqualStrings("alpha", first.text);
    try std.testing.expect(!first.is_null);

    const second = try cellFromArrow(std.testing.allocator, &index_schema, &index_array, 1);
    defer std.testing.allocator.free(second.text);
    try std.testing.expectEqualStrings("beta", second.text);
    try std.testing.expect(!second.is_null);
}

fn buildSingleArrowMetadata(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![:0]u8 {
    const metadata_len = (@sizeOf(i32) * 3) + key.len + value.len;
    var metadata = try allocator.allocSentinel(u8, metadata_len, 0);

    var offset: usize = 0;
    std.mem.writeInt(i32, @ptrCast(metadata.ptr + offset), 1, .little);
    offset += @sizeOf(i32);
    std.mem.writeInt(i32, @ptrCast(metadata.ptr + offset), @intCast(key.len), .little);
    offset += @sizeOf(i32);
    @memcpy(metadata[offset .. offset + key.len], key);
    offset += key.len;
    std.mem.writeInt(i32, @ptrCast(metadata.ptr + offset), @intCast(value.len), .little);
    offset += @sizeOf(i32);
    @memcpy(metadata[offset .. offset + value.len], value);

    return metadata;
}

test "adbc backend recognizes arrow extension and view logical types" {
    const metadata = try buildSingleArrowMetadata(std.testing.allocator, arrow_extension_name_key, "arrow.json");
    defer std.testing.allocator.free(metadata);

    var schema = ArrowSchema{
        .format = "u",
        .metadata = metadata.ptr,
    };
    const uuid_metadata = try buildSingleArrowMetadata(std.testing.allocator, arrow_extension_name_key, "arrow.uuid");
    defer std.testing.allocator.free(uuid_metadata);
    var uuid_schema = ArrowSchema{
        .format = "u",
        .metadata = uuid_metadata.ptr,
    };

    try std.testing.expectEqual(types.ColumnType.json, mapArrowSchemaToColumnType(&schema));
    try std.testing.expectEqual(types.ColumnType.uuid, mapArrowSchemaToColumnType(&uuid_schema));
    try std.testing.expectEqual(types.ColumnType.text, mapArrowFormatToColumnType("vu"));
    try std.testing.expectEqual(types.ColumnType.binary, mapArrowFormatToColumnType("vz"));
    try std.testing.expectEqual(types.ColumnType.int8, mapArrowFormatToColumnType("c"));
    try std.testing.expectEqual(types.ColumnType.uint8, mapArrowFormatToColumnType("C"));
    try std.testing.expectEqual(types.ColumnType.int16, mapArrowFormatToColumnType("s"));
    try std.testing.expectEqual(types.ColumnType.uint16, mapArrowFormatToColumnType("S"));
    try std.testing.expectEqual(types.ColumnType.int32, mapArrowFormatToColumnType("i"));
    try std.testing.expectEqual(types.ColumnType.uint32, mapArrowFormatToColumnType("I"));
    try std.testing.expectEqual(types.ColumnType.int64, mapArrowFormatToColumnType("l"));
    try std.testing.expectEqual(types.ColumnType.uint64, mapArrowFormatToColumnType("L"));
    try std.testing.expectEqual(types.ColumnType.float16, mapArrowFormatToColumnType("e"));
    try std.testing.expectEqual(types.ColumnType.float32, mapArrowFormatToColumnType("f"));
    try std.testing.expectEqual(types.ColumnType.float64, mapArrowFormatToColumnType("g"));
    try std.testing.expectEqual(types.ColumnType.date, mapArrowFormatToColumnType("tdD"));
    try std.testing.expectEqual(types.ColumnType.time, mapArrowFormatToColumnType("ttu"));
    try std.testing.expectEqual(types.ColumnType.interval, mapArrowFormatToColumnType("tin"));
    try std.testing.expectEqual(types.ColumnType.duration, mapArrowFormatToColumnType("tDu"));
    try std.testing.expectEqual(types.ColumnType.array, mapArrowFormatToColumnType("+l"));
    try std.testing.expectEqual(types.ColumnType.map, mapArrowFormatToColumnType("+m"));
    try std.testing.expectEqual(types.ColumnType.struct_, mapArrowFormatToColumnType("+s"));
}

test "adbc backend recognizes PostgreSQL typname metadata overrides" {
    const uuid_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "uuid");
    defer std.testing.allocator.free(uuid_metadata);
    var uuid_schema = ArrowSchema{
        .format = "w:16",
        .metadata = uuid_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.uuid, mapArrowSchemaToColumnType(&uuid_schema));
    try std.testing.expectEqualStrings("uuid", rawTypeFromSchema(&uuid_schema).?);

    const inet_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "inet");
    defer std.testing.allocator.free(inet_metadata);
    var inet_schema = ArrowSchema{
        .format = "z",
        .metadata = inet_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.unknown, mapArrowSchemaToColumnType(&inet_schema));

    const regtype_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "regtype");
    defer std.testing.allocator.free(regtype_metadata);
    var regtype_schema = ArrowSchema{
        .format = "i",
        .metadata = regtype_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.int32, mapArrowSchemaToColumnType(&regtype_schema));

    const lsn_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "pg_lsn");
    defer std.testing.allocator.free(lsn_metadata);
    var lsn_schema = ArrowSchema{
        .format = "w:8",
        .metadata = lsn_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.unknown, mapArrowSchemaToColumnType(&lsn_schema));

    const tsvector_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "tsvector");
    defer std.testing.allocator.free(tsvector_metadata);
    var tsvector_schema = ArrowSchema{
        .format = "z",
        .metadata = tsvector_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.unknown, mapArrowSchemaToColumnType(&tsvector_schema));

    const point_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "point");
    defer std.testing.allocator.free(point_metadata);
    var point_schema = ArrowSchema{
        .format = "w:16",
        .metadata = point_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.unknown, mapArrowSchemaToColumnType(&point_schema));

    const array_metadata = try buildSingleArrowMetadata(std.testing.allocator, postgres_typname_key, "_int4");
    defer std.testing.allocator.free(array_metadata);
    var array_schema = ArrowSchema{
        .format = "+l",
        .metadata = array_metadata.ptr,
    };
    try std.testing.expectEqual(types.ColumnType.array, mapArrowSchemaToColumnType(&array_schema));
}

test "adbc backend formats PostgreSQL opaque system types" {
    const oid_text = try formatPostgresOidLikeBytes(std.testing.allocator, &.{ 0x00, 0x00, 0x00, 0x17 });
    defer std.testing.allocator.free(oid_text);
    try std.testing.expectEqualStrings("23", oid_text);

    const lsn_text = try formatPostgresLsnBytes(std.testing.allocator, &.{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x6b, 0x6c, 0x50 });
    defer std.testing.allocator.free(lsn_text);
    try std.testing.expectEqualStrings("0/16B6C50", lsn_text);

    const tid_text = try formatPostgresTidBytes(std.testing.allocator, &.{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x02 });
    defer std.testing.allocator.free(tid_text);
    try std.testing.expectEqualStrings("(1,2)", tid_text);
}

test "adbc backend formats PostgreSQL text search and geometry types" {
    const tsvector_text = try formatPostgresTsVectorBytes(std.testing.allocator, &.{
        0x00, 0x00, 0x00, 0x02,
        'h',  'e',  'l',  'l',
        'o',  0x00, 0x00, 0x01,
        0x00, 0x01, 'w',  'o',
        'r',  'l',  'd',  0x00,
        0x00, 0x01, 0x00, 0x02,
    });
    defer std.testing.allocator.free(tsvector_text);
    try std.testing.expectEqualStrings("'hello':1 'world':2", tsvector_text);

    const tsquery_text = try formatPostgresTsQueryBytes(std.testing.allocator, &.{
        0x00, 0x00, 0x00, 0x03,
        0x02, 0x02, 0x01, 0x00,
        0x00, 'w',  'o',  'r',
        'l',  'd',  0x00, 0x01,
        0x00, 0x00, 'h',  'e',
        'l',  'l',  'o',  0x00,
    });
    defer std.testing.allocator.free(tsquery_text);
    try std.testing.expectEqualStrings("'hello' & 'world'", tsquery_text);

    const point_text = try formatPostgresPointBytes(std.testing.allocator, &.{
        0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    });
    defer std.testing.allocator.free(point_text);
    try std.testing.expectEqualStrings("(1,2)", point_text);

    const box_text = try formatPostgresBoxBytes(std.testing.allocator, &.{
        0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    });
    defer std.testing.allocator.free(box_text);
    try std.testing.expectEqualStrings("(1,1),(0,0)", box_text);
}

fn freeColumns(allocator: std.mem.Allocator, columns: []const types.ColumnMetadata) void {
    for (columns) |column| {
        allocator.free(column.name);
        if (column.raw_type) |raw_type| allocator.free(raw_type);
    }
    allocator.free(columns);
}

fn freeRows(allocator: std.mem.Allocator, rows: []const types.ResultRow) void {
    for (rows) |row| {
        for (row.values) |cell| {
            allocator.free(cell.text);
        }
        allocator.free(row.values);
    }
    allocator.free(rows);
}

fn buildGetTablesSql(
    allocator: std.mem.Allocator,
    vendor_name: []const u8,
    options: types.GetTablesOptions,
) ![]u8 {
    var sql = std.ArrayList(u8).empty;
    errdefer sql.deinit(allocator);
    var writer = sql.writer(allocator);

    if (std.mem.eql(u8, vendor_name, "sqlite")) {
        try writer.writeAll(
            "select '' as catalog_name, 'main' as database_name, name as table_name, upper(type) as table_type " ++
                "from main.sqlite_schema where type in ('table', 'view')",
        );
        if (options.catalog) |catalog| {
            if (catalog.len != 0) {
                try writer.writeAll(" and 1 = 0");
            }
        }
        if (options.database) |database| {
            if (!std.mem.eql(u8, database, "main")) {
                try writer.writeAll(" and 1 = 0");
            }
        }
        try writer.writeAll(" order by table_name");
        return sql.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, vendor_name, "clickhouse")) {
        try writer.writeAll(
            "select '' as catalog_name, database as database_name, name as table_name, engine as table_type " ++
                "from system.tables where 1 = 1",
        );
        if (options.catalog) |catalog| {
            if (catalog.len != 0) {
                try writer.writeAll(" and 1 = 0");
            }
        }
        if (options.database) |database| {
            try appendSqlEqualsFilter(allocator, &sql, "database", database);
        }
        try writer.writeAll(" order by database_name, table_name");
        return sql.toOwnedSlice(allocator);
    }

    if (std.mem.eql(u8, vendor_name, "exasol")) {
        try writer.writeAll(
            "select '' as catalog_name, table_schema as database_name, table_name, table_type " ++
                "from EXA_ALL_TABLES where 1 = 1",
        );
        if (options.catalog) |catalog| {
            if (catalog.len != 0) {
                try writer.writeAll(" and 1 = 0");
            }
        }
        if (options.database) |database| {
            try appendSqlEqualsFilter(allocator, &sql, "table_schema", database);
        }
        try writer.writeAll(" order by database_name, table_name");
        return sql.toOwnedSlice(allocator);
    }

    try writer.writeAll(
        "select table_catalog as catalog_name, table_schema as database_name, table_name, table_type " ++
            "from information_schema.tables where 1 = 1",
    );
    if (options.catalog) |catalog| {
        try appendSqlEqualsFilter(allocator, &sql, "table_catalog", catalog);
    }
    if (options.database) |database| {
        try appendSqlEqualsFilter(allocator, &sql, "table_schema", database);
    }
    try writer.writeAll(" order by catalog_name, database_name, table_name");
    return sql.toOwnedSlice(allocator);
}

fn buildGetDatabasesSql(allocator: std.mem.Allocator, vendor_name: []const u8) ![]u8 {
    if (std.mem.eql(u8, vendor_name, "sqlite")) {
        return allocator.dupe(u8, "select 'main' as database_name");
    }
    if (std.mem.eql(u8, vendor_name, "postgresql") or std.mem.eql(u8, vendor_name, "redshift")) {
        return allocator.dupe(u8, "select datname as database_name from pg_database where datistemplate = false order by datname");
    }
    if (std.mem.eql(u8, vendor_name, "clickhouse")) {
        return allocator.dupe(u8, "select name as database_name from system.databases order by name");
    }
    if (std.mem.eql(u8, vendor_name, "exasol")) {
        return allocator.dupe(u8, "select schema_name as database_name from EXA_ALL_SCHEMAS order by schema_name");
    }
    return allocator.dupe(u8, "select schema_name as database_name from information_schema.schemata order by schema_name");
}

fn appendTableQualifiedNames(
    allocator: std.mem.Allocator,
    vendor_name: []const u8,
    result_set: *driver.ResultSetHandle,
) !void {
    if (result_set.columns.len < 4) return;

    const namespace_role = tableNamespaceRole(vendor_name);
    const namespace_kind = @tagName(namespace_role);
    const old_columns = result_set.columns;
    const old_rows = result_set.rows;

    const new_columns = try allocator.alloc(types.ColumnMetadata, old_columns.len + 2);
    errdefer allocator.free(new_columns);

    for (old_columns, 0..) |column, index| {
        new_columns[index] = column;
    }

    new_columns[old_columns.len] = .{
        .name = try allocator.dupe(u8, "namespace_kind"),
        .column_type = .text,
        .nullable = false,
    };
    errdefer allocator.free(new_columns[old_columns.len].name);

    new_columns[old_columns.len + 1] = .{
        .name = try allocator.dupe(u8, "qualified_name"),
        .column_type = .text,
        .nullable = false,
    };
    errdefer allocator.free(new_columns[old_columns.len + 1].name);

    const new_rows = try allocator.alloc(types.ResultRow, old_rows.len);
    errdefer allocator.free(new_rows);

    var built_rows: usize = 0;
    errdefer {
        for (new_rows[0..built_rows]) |row| {
            allocator.free(row.values[row.values.len - 2].text);
            allocator.free(row.values[row.values.len - 1].text);
            allocator.free(row.values);
        }
    }

    for (old_rows, 0..) |row, index| {
        const new_values = try allocator.alloc(types.ResultCell, row.values.len + 2);
        errdefer allocator.free(new_values);

        for (row.values, 0..) |cell, cell_index| {
            new_values[cell_index] = cell;
        }

        new_values[row.values.len] = .{
            .text = try allocator.dupe(u8, namespace_kind),
            .is_null = false,
        };
        errdefer allocator.free(new_values[row.values.len].text);

        new_values[row.values.len + 1] = .{
            .text = try formatTableQualifiedName(allocator, vendor_name, row),
            .is_null = false,
        };

        new_rows[index] = .{ .values = new_values };
        built_rows += 1;
    }

    for (old_rows) |row| {
        allocator.free(row.values);
    }
    allocator.free(old_rows);
    allocator.free(old_columns);

    result_set.columns = new_columns;
    result_set.rows = new_rows;
}

fn tableNamespaceRole(vendor_name: []const u8) types.QualifiedNamePartRole {
    if (std.mem.eql(u8, vendor_name, "postgresql") or
        std.mem.eql(u8, vendor_name, "redshift") or
        std.mem.eql(u8, vendor_name, "exasol"))
    {
        return .schema;
    }

    if (std.mem.eql(u8, vendor_name, "bigquery")) {
        return .dataset;
    }

    if (std.mem.eql(u8, vendor_name, "snowflake")) {
        return .schema;
    }

    return .database;
}

fn formatTableQualifiedName(
    allocator: std.mem.Allocator,
    vendor_name: []const u8,
    row: types.ResultRow,
) ![]u8 {
    if (row.values.len < 3) {
        return allocator.dupe(u8, "");
    }

    var parts_buffer: [3]types.QualifiedNamePart = undefined;
    var part_count: usize = 0;

    if (!row.values[0].is_null and row.values[0].text.len != 0) {
        parts_buffer[part_count] = .{
            .role = .catalog,
            .value = row.values[0].text,
        };
        part_count += 1;
    }

    if (!row.values[1].is_null and row.values[1].text.len != 0) {
        parts_buffer[part_count] = .{
            .role = tableNamespaceRole(vendor_name),
            .value = row.values[1].text,
        };
        part_count += 1;
    }

    if (!row.values[2].is_null and row.values[2].text.len != 0) {
        parts_buffer[part_count] = .{
            .role = .object,
            .value = row.values[2].text,
        };
        part_count += 1;
    }

    return (types.QualifiedName{ .parts = parts_buffer[0..part_count] }).format(allocator, ".");
}

fn appendSqlEqualsFilter(
    allocator: std.mem.Allocator,
    sql: *std.ArrayList(u8),
    column_name: []const u8,
    value: []const u8,
) !void {
    try sql.print(allocator, " and {s} = ", .{column_name});
    try appendSqlStringLiteral(allocator, sql, value);
}

fn appendSqlStringLiteral(allocator: std.mem.Allocator, sql: *std.ArrayList(u8), value: []const u8) !void {
    try sql.append(allocator, '\'');
    for (value) |char| {
        if (char == '\'') {
            try sql.appendSlice(allocator, "''");
        } else {
            try sql.append(allocator, char);
        }
    }
    try sql.append(allocator, '\'');
}

fn preloadVendorDependencies(allocator: std.mem.Allocator, vendor_driver_path: []const u8) !?*anyopaque {
    _ = allocator;
    if (builtin.os.tag == .windows) {
        return null;
    }
    if (!std.mem.containsAtLeast(u8, vendor_driver_path, 1, "adbc_driver_sqlite")) {
        return null;
    }

    const sqlite_path = resolveCompatibleSqlitePath() orelse return null;
    return dlopen(sqlite_path, globalDlopenFlags()) orelse return Error.DriverLoadFailed;
}

fn resolveCompatibleSqlitePath() ?[*:0]const u8 {
    if (builtin.os.tag == .macos) {
        if (std.fs.accessAbsolute("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib", .{})) {
            return "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib";
        } else |_| {}
        if (std.fs.accessAbsolute("/usr/local/opt/sqlite/lib/libsqlite3.dylib", .{})) {
            return "/usr/local/opt/sqlite/lib/libsqlite3.dylib";
        } else |_| {}
    }
    return null;
}

fn globalDlopenFlags() c_int {
    return switch (builtin.os.tag) {
        .macos => 0x2 | 0x8,
        .linux => 0x2 | 0x100,
        else => 0x2,
    };
}

fn connectionContext(handle: *driver.ConnectionHandle) *ConnectionContext {
    return @ptrFromInt(handle.opaque_handle);
}

fn releaseConnection(context: *ConnectionContext) void {
    if (context.connection.private_data != null) {
        _ = context.runtime.cxn_release(&context.connection, null);
        context.connection = .{};
    }
    releaseDatabase(context);
}

fn releaseDatabase(context: *ConnectionContext) void {
    if (context.database.private_data != null) {
        _ = context.runtime.db_release(&context.database, null);
        context.database = .{};
    }
}

fn lookup(lib: *std.DynLib, comptime T: type, symbol_name: [:0]const u8) T {
    return lib.lookup(T, symbol_name) orelse @panic("missing ADBC symbol");
}

fn requireOk(status: u8, error_info: *AdbcError) !void {
    defer releaseError(error_info);
    if (status == adbc_status_ok) {
        return;
    }

    if (error_info.message) |message| {
        setLastDriverErrorMessage(std.mem.span(message));
    }

    if (status == adbc_status_invalid_argument or status == adbc_status_invalid_state) {
        return Error.InvalidArgument;
    }

    return Error.DriverLoadFailed;
}

pub fn clearLastDriverErrorMessage() void {
    if (last_driver_error_message) |message| {
        std.heap.page_allocator.free(message);
        last_driver_error_message = null;
    }
}

pub fn takeLastDriverErrorMessage(allocator: std.mem.Allocator) ?[]u8 {
    const message = last_driver_error_message orelse return null;
    defer {
        std.heap.page_allocator.free(message);
        last_driver_error_message = null;
    }
    return allocator.dupe(u8, message) catch null;
}

fn setLastDriverErrorMessage(message: []const u8) void {
    clearLastDriverErrorMessage();
    last_driver_error_message = std.heap.page_allocator.dupe(u8, message) catch null;
}

fn releaseError(error_info: *AdbcError) void {
    if (error_info.release) |release| {
        release(error_info);
    }
    error_info.* = .{};
}

fn withSentinel(
    allocator: std.mem.Allocator,
    value: []const u8,
    comptime Func: anytype,
    runtime: *const Runtime,
    ptr: anytype,
    error_info: *AdbcError,
) !void {
    const sentinel = try allocator.dupeZ(u8, value);
    defer allocator.free(sentinel);
    return Func(runtime, ptr, sentinel, error_info);
}

fn withSentinel2(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    comptime Func: anytype,
    runtime: *const Runtime,
    database: *AdbcDatabase,
    error_info: *AdbcError,
) !void {
    const key_z = try allocator.dupeZ(u8, key);
    defer allocator.free(key_z);
    const value_z = try allocator.dupeZ(u8, value);
    defer allocator.free(value_z);
    return Func(runtime, database, key_z, value_z, error_info);
}

extern fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlclose(handle: ?*anyopaque) c_int;
