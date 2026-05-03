const std = @import("std");
const aq = @import("root.zig");

const RepoTmpCase = struct {
    rel_dir: []u8,
    abs_dir: []u8,

    fn create(allocator: std.mem.Allocator, prefix: []const u8) !RepoTmpCase {
        var random_bytes: [12]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);

        var suffix: [std.fs.base64_encoder.calcSize(random_bytes.len)]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&suffix, &random_bytes);

        const rel_dir = try std.fmt.allocPrint(allocator, ".tmp/src-aq-core-tests/{s}-{s}", .{ prefix, suffix[0..] });
        errdefer allocator.free(rel_dir);

        try std.fs.cwd().makePath(rel_dir);
        errdefer std.fs.cwd().deleteTree(rel_dir) catch {};

        const abs_dir = try std.fs.cwd().realpathAlloc(allocator, rel_dir);
        errdefer allocator.free(abs_dir);

        return .{
            .rel_dir = rel_dir,
            .abs_dir = abs_dir,
        };
    }

    fn deinit(self: *RepoTmpCase, allocator: std.mem.Allocator) void {
        allocator.free(self.abs_dir);
        allocator.free(self.rel_dir);
        self.* = undefined;
    }

    fn writeFile(self: RepoTmpCase, sub_path: []const u8, data: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.rel_dir, .{});
        defer dir.close();

        try dir.writeFile(.{
            .sub_path = sub_path,
            .data = data,
        });
    }

    fn allocPath(self: RepoTmpCase, allocator: std.mem.Allocator, basename: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.abs_dir, basename });
    }
};

fn expectSingleStringResult(result: aq.QueryResult, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), result.results.len);
    try std.testing.expectEqual(@as(c_int, 0), result.results[0].err.code);
    try std.testing.expectEqual(@as(c_int, 1), result.results[0].ok.len);

    const value = aq.c.sr_array_get(&result.results[0].ok, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(@TypeOf(aq.valueTag(value)), aq.c.SR_VALUE_STRAND), aq.valueTag(value));
    try std.testing.expectEqualStrings(expected, try aq.valueString(value));
}

fn singleValue(result: aq.QueryResult) !*const aq.c.sr_value_t {
    try std.testing.expectEqual(@as(usize, 1), result.results.len);
    try std.testing.expectEqual(@as(c_int, 0), result.results[0].err.code);
    try std.testing.expectEqual(@as(c_int, 1), result.results[0].ok.len);

    return aq.c.sr_array_get(&result.results[0].ok, 0) orelse error.TestUnexpectedResult;
}

test {
    _ = aq;
}

test "embedded SurrealQL fixture imports into embedded surrealdb" {
    const seed = @embedFile("fixtures/embedded_seed.surql");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "embedded_seed.surql",
        .data = seed,
    });

    const imported_path = try tmp.dir.realpathAlloc(std.testing.allocator, "embedded_seed.surql");
    defer std.testing.allocator.free(imported_path);

    const imported_path_z = try std.testing.allocator.dupeZ(u8, imported_path);
    defer std.testing.allocator.free(imported_path_z);

    var client = try aq.Client.connectEmbedded(std.testing.allocator, .memory);
    defer client.deinit();

    try client.useNamespace("embed_test");
    try client.useDatabase("embed_test");
    try client.importFile(imported_path_z);

    const result = try client.query("RETURN (SELECT VALUE name FROM person:embedded)[0];", .{});
    defer {
        var mutable = result;
        mutable.deinit();
    }

    try expectSingleStringResult(result, "embedded");
}

test "surrealkv endpoint stores embedded database under .tmp" {
    const seed = @embedFile("fixtures/embedded_seed.surql");

    var repo_tmp = try RepoTmpCase.create(std.testing.allocator, "surrealkv");
    defer repo_tmp.deinit(std.testing.allocator);

    try repo_tmp.writeFile("embedded_seed.surql", seed);

    const seed_path = try repo_tmp.allocPath(std.testing.allocator, "embedded_seed.surql");
    defer std.testing.allocator.free(seed_path);

    const seed_path_z = try std.testing.allocator.dupeZ(u8, seed_path);
    defer std.testing.allocator.free(seed_path_z);

    const store_path = try repo_tmp.allocPath(std.testing.allocator, "surreal-store.skv");
    defer std.testing.allocator.free(store_path);

    const store_rel_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ repo_tmp.rel_dir, "surreal-store.skv" });
    defer std.testing.allocator.free(store_rel_path);

    {
        var client = try aq.Client.connectEmbedded(std.testing.allocator, .{ .surrealkv = store_path });
        defer client.deinit();

        try client.useNamespace("surrealkv_test");
        try client.useDatabase("surrealkv_test");
        try client.importFile(seed_path_z);

        const result = try client.query("RETURN (SELECT VALUE source FROM person:embedded)[0];", .{});
        defer {
            var mutable = result;
            mutable.deinit();
        }

        try expectSingleStringResult(result, "embed-file");
    }

    var store_dir = try std.fs.cwd().openDir(store_rel_path, .{ .iterate = true });
    defer store_dir.close();

    var iterator = store_dir.iterate();
    try std.testing.expect((try iterator.next()) != null);
}

test "surrealkv versioned endpoint supports time travel queries" {
    var repo_tmp = try RepoTmpCase.create(std.testing.allocator, "surrealkv-versioned");
    defer repo_tmp.deinit(std.testing.allocator);

    const store_path_base = try repo_tmp.allocPath(std.testing.allocator, "surreal-versioned.skv");
    defer std.testing.allocator.free(store_path_base);

    const store_path_versioned = try std.fmt.allocPrint(std.testing.allocator, "{s}?versioned=true", .{store_path_base});
    defer std.testing.allocator.free(store_path_versioned);

    var client = try aq.Client.connectEmbedded(std.testing.allocator, .{ .surrealkv = store_path_versioned });
    defer client.deinit();

    try client.useNamespace("surrealkv_versioned_test");
    try client.useDatabase("surrealkv_versioned_test");

    {
        const result = try client.query("CREATE person:timetravel SET name = 'John v1';", .{});
        defer {
            var mutable = result;
            mutable.deinit();
        }
    }

    const timestamp_result = try client.query("RETURN time::now();", .{});
    const version_value = try singleValue(timestamp_result);
    const version_ts = try std.testing.allocator.dupe(u8, try aq.valueDateTime(version_value));
    defer std.testing.allocator.free(version_ts);
    defer {
        var mutable = timestamp_result;
        mutable.deinit();
    }

    {
        const result = try client.query("UPDATE person:timetravel SET name = 'John v2';", .{});
        defer {
            var mutable = result;
            mutable.deinit();
        }
    }

    {
        const result = try client.query("RETURN (SELECT VALUE name FROM person:timetravel)[0];", .{});
        defer {
            var mutable = result;
            mutable.deinit();
        }

        try expectSingleStringResult(result, "John v2");
    }

    const historical_query = try std.fmt.allocPrint(
        std.testing.allocator,
        "RETURN (SELECT VALUE name FROM person:timetravel VERSION d'{s}')[0];",
        .{version_ts},
    );
    defer std.testing.allocator.free(historical_query);

    const historical_query_z = try std.testing.allocator.dupeZ(u8, historical_query);
    defer std.testing.allocator.free(historical_query_z);

    {
        const result = try client.query(historical_query_z, .{});
        defer {
            var mutable = result;
            mutable.deinit();
        }

        try expectSingleStringResult(result, "John v1");
    }
}
