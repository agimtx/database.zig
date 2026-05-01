pub const types = @import("core/types.zig");
pub const driver = @import("core/driver.zig");
pub const registry = @import("core/registry.zig");
pub const manager = @import("core/manager.zig");
pub const ffi = @import("ffi/c_api.zig");

comptime {
    _ = ffi.module_anchor;
}

pub const DriverKind = types.DriverKind;
pub const DriverLanguage = types.DriverLanguage;
pub const ColumnType = types.ColumnType;
pub const ColumnMetadata = types.ColumnMetadata;
pub const ResultCell = types.ResultCell;
pub const ResultRow = types.ResultRow;
pub const QualifiedNamePartRole = types.QualifiedNamePartRole;
pub const QualifiedNamePart = types.QualifiedNamePart;
pub const QualifiedName = types.QualifiedName;
pub const ConnectOptions = types.ConnectOptions;
pub const GetTablesOptions = types.GetTablesOptions;

pub const ConnectionHandle = driver.ConnectionHandle;
pub const ResultSetHandle = driver.ResultSetHandle;
pub const CursorHandle = driver.CursorHandle;
pub const DriverSpec = driver.DriverSpec;

pub const DriverRegistry = registry.DriverRegistry;
pub const ConnectionManager = manager.ConnectionManager;
pub const ConnectionError = manager.ConnectionError;

test {
    _ = @import("core/manager.zig");
    _ = @import("ffi/c_api.zig");
}
