const std = @import("std");
const types = @import("types.zig");
const driver = @import("driver.zig");

pub const DriverRegistry = struct {
    allocator: std.mem.Allocator,
    drivers: std.AutoHashMap(types.DriverKind, driver.DriverSpec),

    pub fn init(allocator: std.mem.Allocator) DriverRegistry {
        return .{
            .allocator = allocator,
            .drivers = std.AutoHashMap(types.DriverKind, driver.DriverSpec).init(allocator),
        };
    }

    pub fn deinit(self: *DriverRegistry) void {
        self.drivers.deinit();
    }

    pub fn register(self: *DriverRegistry, spec: driver.DriverSpec) !void {
        try self.drivers.put(spec.kind, spec);
    }

    pub fn resolve(self: *const DriverRegistry, kind: types.DriverKind) ?driver.DriverSpec {
        return self.drivers.get(kind);
    }

    pub fn count(self: *const DriverRegistry) usize {
        return self.drivers.count();
    }

    pub fn registerBuiltins(self: *DriverRegistry) !void {
        inline for ([_]types.DriverKind{
            .adbc,
        }) |kind| {
            try self.register(.{
                .kind = kind,
                .name = builtinName(kind),
                .language = .shared_library,
                .open = driver.stubOpen,
                .close = driver.stubClose,
                .execute = driver.stubExecute,
                .close_result_set = driver.stubCloseResultSet,
                .open_cursor = driver.stubOpenCursor,
                .fetch_cursor_next = driver.stubFetchCursorNext,
                .close_cursor = driver.stubCloseCursor,
            });
        }
    }
};

fn builtinName(kind: types.DriverKind) []const u8 {
    return switch (kind) {
        .adbc => "adbc",
        .custom => "custom",
    };
}
