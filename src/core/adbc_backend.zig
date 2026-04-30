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
    const uri = parsed.uri orelse options.dsn;
    const inferred_driver_name = inferDriverName(uri);

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
    try setDatabaseOption(temp, &context.runtime, &context.database, reserved_option_uri, uri, &error_info);

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
    return execute(allocator, handle, result_set_id, sql);
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
        columns[index] = .{
            .name = try allocator.dupe(u8, name),
            .column_type = mapArrowFormatToColumnType(if (child.format) |fmt| std.mem.span(fmt) else ""),
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
) !types.ResultCell {
    if (isNullAt(array, row_index)) {
        return .{
            .text = try allocator.alloc(u8, 0),
            .is_null = true,
        };
    }

    const format = if (schema.format) |value| std.mem.span(value) else "";
    return .{
        .text = try extractArrowValueText(allocator, format, array, row_index),
        .is_null = false,
    };
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
    format: []const u8,
    array: *ArrowArray,
    row_index: usize,
) ![]u8 {
    if (format.len == 0) {
        return allocator.alloc(u8, 0);
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
        'd' => formatArrowBinaryWord(allocator, 16, array, row_index),
        't', 'T' => formatArrowInt(allocator, i64, array, row_index),
        else => allocator.alloc(u8, 0),
    };
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

fn mapArrowFormatToColumnType(format: []const u8) types.ColumnType {
    if (format.len == 0) return .unknown;
    return switch (format[0]) {
        'b' => .boolean,
        'c', 'C', 's', 'S', 'i', 'I', 'l', 'L' => .int64,
        'f', 'g' => .float64,
        'u', 'U' => .text,
        'z', 'Z', 'w' => .binary,
        'd' => .decimal,
        't', 'T' => .timestamp,
        else => .unknown,
    };
}

fn freeColumns(allocator: std.mem.Allocator, columns: []const types.ColumnMetadata) void {
    for (columns) |column| {
        allocator.free(column.name);
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
        std.log.err("ADBC status={d} message={s}", .{ status, std.mem.span(message) });
    } else {
        std.log.err("ADBC status={d}", .{status});
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
