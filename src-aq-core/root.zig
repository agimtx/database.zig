const std = @import("std");

pub const c = @cImport({
    @cInclude("surrealdb.h");
});

pub const Error = error{
    SurrealFailure,
    FatalFailure,
    InvalidUtf8,
    UnexpectedValueType,
    OutOfMemory,
};

pub const EmbeddedEndpoint = union(enum) {
    memory,
    surrealkv: []const u8,

    pub fn write(self: EmbeddedEndpoint, writer: anytype) !void {
        switch (self) {
            .memory => try writer.writeAll("mem://"),
            .surrealkv => |path| try writer.print("surrealkv://{s}", .{path}),
        }
    }
};

pub const SignInOptions = struct {
    username: [:0]const u8,
    password: [:0]const u8,
    namespace: ?[:0]const u8 = null,
    database: ?[:0]const u8 = null,
};

pub const QueryOptions = struct {
    vars: ?*const c.sr_object_t = null,
};

pub const QueryResult = struct {
    results: []c.sr_arr_res_t,

    pub fn deinit(self: *QueryResult) void {
        if (self.results.len == 0) {
            return;
        }
        c.sr_free_arr_res_arr(self.results.ptr, @intCast(self.results.len));
        self.* = .{ .results = &.{} };
    }

    pub fn writeDebug(self: QueryResult, writer: anytype) !void {
        for (self.results, 0..) |item, index| {
            if (index != 0) try writer.writeAll("\n");
            try writer.print("statement[{d}]", .{index});
            if (item.err.code != 0) {
                const err_msg = item.err.msg orelse "<unknown error>";
                try writer.print(" error({d}): {s}", .{ item.err.code, std.mem.span(err_msg) });
                continue;
            }

            try writer.print(" ok[{d}]", .{item.ok.len});
            var value_index: usize = 0;
            while (value_index < @as(usize, @intCast(item.ok.len))) : (value_index += 1) {
                const value = c.sr_array_get(&item.ok, @intCast(value_index)) orelse continue;
                try writer.writeAll("\n  - ");
                try writeValueDebug(value, writer);
            }
        }
    }
};

pub fn valueTag(value: *const c.sr_value_t) @TypeOf(value.*.tag) {
    return value.*.tag;
}

pub fn valueString(value: *const c.sr_value_t) Error![]const u8 {
    if (valueTag(value) != @as(@TypeOf(value.*.tag), c.SR_VALUE_STRAND)) {
        return error.UnexpectedValueType;
    }

    return std.mem.span(value.*.unnamed_0.unnamed_2.sr_value_strand);
}

pub fn valueDateTime(value: *const c.sr_value_t) Error![]const u8 {
    if (valueTag(value) != @as(@TypeOf(value.*.tag), c.SR_VALUE_DATETIME)) {
        return error.UnexpectedValueType;
    }

    return std.mem.span(value.*.unnamed_0.unnamed_4.sr_value_datetime);
}

pub const ObjectBuilder = struct {
    inner: c.sr_object_t,

    pub fn init() ObjectBuilder {
        return .{ .inner = c.sr_object_new() };
    }

    pub fn deinit(self: *ObjectBuilder) void {
        c.sr_free_object(self.inner);
    }

    pub fn putString(self: *ObjectBuilder, key: [:0]const u8, value: [:0]const u8) void {
        c.sr_object_insert_str(&self.inner, key.ptr, value.ptr);
    }

    pub fn putInt(self: *ObjectBuilder, key: [:0]const u8, value: i32) void {
        c.sr_object_insert_int(&self.inner, key.ptr, value);
    }

    pub fn borrow(self: *const ObjectBuilder) *const c.sr_object_t {
        return &self.inner;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    raw: *c.sr_surreal_t,

    pub fn connectEmbedded(allocator: std.mem.Allocator, endpoint: EmbeddedEndpoint) !Client {
        const endpoint_z = try dupEndpointZ(allocator, endpoint);
        defer allocator.free(endpoint_z);

        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);

        var raw: ?*c.sr_surreal_t = null;
        const status = c.sr_connect(&err_ptr, &raw, endpoint_z.ptr);
        try statusToError(status, err_ptr);

        return .{
            .allocator = allocator,
            .raw = raw orelse return error.SurrealFailure,
        };
    }

    pub fn deinit(self: *Client) void {
        c.sr_surreal_disconnect(self.raw);
        self.* = undefined;
    }

    pub fn useNamespace(self: *const Client, namespace: [:0]const u8) !void {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);
        const status = c.sr_use_ns(self.raw, &err_ptr, namespace.ptr);
        try statusToError(status, err_ptr);
    }

    pub fn useDatabase(self: *const Client, database: [:0]const u8) !void {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);
        const status = c.sr_use_db(self.raw, &err_ptr, database.ptr);
        try statusToError(status, err_ptr);
    }

    pub fn signInRoot(self: *const Client, options: SignInOptions) !?[]u8 {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);

        var token: c.sr_string_t = null;
        defer if (token != null) c.sr_free_string(token);

        var scope = c.ROOT;
        var creds = c.sr_credentials{
            .username = @constCast(options.username.ptr),
            .password = @constCast(options.password.ptr),
        };

        var details = c.sr_credentials_access{
            .namespace_ = if (options.namespace) |value| @constCast(value.ptr) else null,
            .database = if (options.database) |value| @constCast(value.ptr) else null,
            .access = null,
        };

        const details_ptr: ?*const c.sr_credentials_access = if (options.namespace != null or options.database != null) &details else null;
        const status = c.sr_signin(self.raw, &err_ptr, &token, &scope, &creds, details_ptr, null);
        try statusToError(status, err_ptr);

        if (token == null) return null;
        return dupeSurrealString(self.allocator, token.?);
    }

    pub fn health(self: *const Client) !void {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);
        const status = c.sr_health(self.raw, &err_ptr);
        try statusToError(status, err_ptr);
    }

    pub fn importFile(self: *const Client, file_path: [:0]const u8) !void {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);

        const status = c.sr_import(self.raw, &err_ptr, file_path.ptr);
        try statusToError(status, err_ptr);
    }

    pub fn version(self: *const Client) ![]u8 {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);

        var version_ptr: c.sr_string_t = null;
        defer if (version_ptr != null) c.sr_free_string(version_ptr);

        const status = c.sr_version(self.raw, &err_ptr, &version_ptr);
        try statusToError(status, err_ptr);

        return dupeSurrealString(self.allocator, version_ptr orelse return error.SurrealFailure);
    }

    pub fn query(self: *const Client, sql: [:0]const u8, options: QueryOptions) !QueryResult {
        var err_ptr: c.sr_string_t = null;
        defer freeSurrealString(err_ptr);

        var raw_results: ?[*]c.sr_arr_res_t = null;
        const len = c.sr_query(self.raw, &err_ptr, @ptrCast(&raw_results), sql.ptr, if (options.vars) |vars| vars else null);
        try statusToError(len, err_ptr);

        const results_ptr = raw_results orelse return .{ .results = &.{} };
        return .{ .results = results_ptr[0..@intCast(len)] };
    }
};

fn dupEndpointZ(allocator: std.mem.Allocator, endpoint: EmbeddedEndpoint) ![:0]u8 {
    return switch (endpoint) {
        .memory => allocator.dupeZ(u8, "mem://"),
        .surrealkv => |path| blk: {
            const prefix = "surrealkv://";
            var buffer = try allocator.allocSentinel(u8, prefix.len + path.len, 0);
            @memcpy(buffer[0..prefix.len], prefix);
            @memcpy(buffer[prefix.len .. prefix.len + path.len], path);
            break :blk buffer;
        },
    };
}

fn writeValueDebug(value: *const c.sr_value_t, writer: anytype) !void {
    switch (value.tag) {
        c.SR_VALUE_NONE => try writer.writeAll("NONE"),
        c.SR_VALUE_NULL => try writer.writeAll("NULL"),
        c.SR_VALUE_BOOL => try writer.print("BOOL({})", .{value.sr_value_bool}),
        c.SR_VALUE_NUMBER => switch (value.sr_value_number.tag) {
            c.SR_NUMBER_INT => try writer.print("INT({d})", .{value.sr_value_number.sr_number_int}),
            c.SR_NUMBER_FLOAT => try writer.print("FLOAT({d})", .{value.sr_value_number.sr_number_float}),
            c.SR_NUMBER_DECIMAL => try writer.print("DECIMAL({s})", .{std.mem.span(value.sr_value_number.sr_number_decimal)}),
            else => try writer.writeAll("NUMBER(?)"),
        },
        c.SR_VALUE_STRAND => try writer.print("STRING({s})", .{std.mem.span(value.sr_value_strand)}),
        c.SR_VALUE_DATETIME => try writer.print("DATETIME({s})", .{std.mem.span(value.sr_value_datetime)}),
        c.SR_VALUE_ARRAY => try writer.writeAll("ARRAY(...)"),
        c.SR_VALUE_OBJECT => try writer.writeAll("OBJECT(...)"),
        c.SR_GEOMETRY_OBJECT => try writer.writeAll("GEOMETRY(...)"),
        c.SR_VALUE_BYTES => try writer.print("BYTES(len={d})", .{value.sr_value_bytes.len}),
        c.SR_VALUE_THING => try writer.print(
            "THING({s})",
            .{std.mem.span(value.sr_value_thing.table)},
        ),
        c.SR_VALUE_UUID => try writer.writeAll("UUID(...)"),
        c.SR_VALUE_DURATION => try writer.print(
            "DURATION({d}s,{d}ns)",
            .{ value.sr_value_duration.secs, value.sr_value_duration.nanos },
        ),
        else => try writer.writeAll("UNKNOWN"),
    }
}

fn freeSurrealString(value: c.sr_string_t) void {
    if (value != null) {
        c.sr_free_string(value);
    }
}

fn statusToError(status: anytype, err_ptr: c.sr_string_t) !void {
    const code: i32 = @intCast(status);
    if (code >= 0) return;

    if (err_ptr != null) {
        std.log.err("surrealdb: {s}", .{std.mem.span(err_ptr)});
    }

    return switch (code) {
        c.sr_SR_FATAL => error.FatalFailure,
        else => error.SurrealFailure,
    };
}

fn dupeSurrealString(allocator: std.mem.Allocator, value: [*:0]u8) ![]u8 {
    const span = std.mem.span(value);
    if (!std.unicode.utf8ValidateSlice(span)) {
        return error.InvalidUtf8;
    }
    return allocator.dupe(u8, span);
}

test "embedded memory endpoint query roundtrip" {
    var client = try Client.connectEmbedded(std.testing.allocator, .memory);
    defer client.deinit();

    try client.useNamespace("test");
    try client.useDatabase("test");
    try client.health();

    const result = try client.query("RETURN 'ok';", .{});
    defer {
        var mutable = result;
        mutable.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), result.results.len);
    try std.testing.expectEqual(@as(c_int, 0), result.results[0].err.code);
    try std.testing.expectEqual(@as(c_int, 1), result.results[0].ok.len);

    const value = c.sr_array_get(&result.results[0].ok, 0) orelse return error.SurrealFailure;
    try std.testing.expectEqual(@as(@TypeOf(valueTag(value)), c.SR_VALUE_STRAND), valueTag(value));
    try std.testing.expectEqualStrings("ok", try valueString(value));
}
