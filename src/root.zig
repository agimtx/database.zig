pub const types = @import("core/types.zig");
pub const driver = @import("core/driver.zig");
pub const registry = @import("core/registry.zig");
pub const manager = @import("core/manager.zig");
pub const ffi = @import("ffi/c_api.zig");

pub const DriverKind = types.DriverKind;
pub const DriverLanguage = types.DriverLanguage;
pub const ColumnType = types.ColumnType;
pub const ColumnMetadata = types.ColumnMetadata;
pub const ConnectOptions = types.ConnectOptions;

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
