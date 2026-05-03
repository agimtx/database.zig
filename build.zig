const std = @import("std");

const adbc_include_dir = "third_party/adbc/1.11.0/include";
const surrealdb_include_dir = "third_party/surrealdb/include";

fn surrealdbLibSubdir(target: std.Build.ResolvedTarget) []const u8 {
    const os_tag = target.result.os.tag;
    const arch = target.result.cpu.arch;

    if (os_tag == .macos and arch == .aarch64) {
        return "macos-arm64";
    }

    @panic("src-aq-core currently expects a vendored surrealdb shared library for this target");
}

fn deleteFileIfExists(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.panic("failed to delete legacy artifact {s}: {s}", .{ path, @errorName(err) }),
    };
}

fn removeLegacyInstallArtifacts() void {
    deleteFileIfExists("zig-out/lib/libdatabase_zig.dylib");
    deleteFileIfExists("zig-out/lib/libdatabase_zig.so");
    deleteFileIfExists("zig-out/lib/database_zig.dll");
    deleteFileIfExists("zig-out/lib/database_zig.lib");
    deleteFileIfExists("zig-out/include/database_zig.h");
}

fn makeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addIncludePath(.{ .cwd_relative = adbc_include_dir });
    return module;
}

fn makeAqCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src-aq-core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addIncludePath(.{ .cwd_relative = surrealdb_include_dir });
    return module;
}

fn makeAqCoreTestModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src-aq-core/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addIncludePath(.{ .cwd_relative = surrealdb_include_dir });
    return module;
}

fn makeCAbiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/c_api_root.zig"),
        .target = target,
        .optimize = optimize,
    });

    module.addIncludePath(.{ .cwd_relative = adbc_include_dir });
    return module;
}

pub fn build(b: *std.Build) void {
    removeLegacyInstallArtifacts();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "aq_database",
        .root_module = makeCAbiModule(b, target, optimize),
    });

    const aq_core_tests = b.addTest(.{
        .root_module = makeAqCoreTestModule(b, target, optimize),
    });
    const run_aq_core_tests = b.addRunArtifact(aq_core_tests);

    aq_core_tests.root_module.linkSystemLibrary("surrealdb", .{});
    aq_core_tests.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ "third_party/surrealdb/lib", surrealdbLibSubdir(target) }) });
    aq_core_tests.linkLibC();

    if (target.result.os.tag == .macos) {
        run_aq_core_tests.setEnvironmentVariable(
            "DYLD_LIBRARY_PATH",
            b.pathJoin(&.{"third_party/surrealdb/tree/target/release/deps"}),
        );
    }

    b.installArtifact(shared_lib);
    b.installFile("bindings/c/include/aq_database.h", "include/aq_database.h");

    const unit_tests = b.addTest(.{
        .root_module = makeModule(b, target, optimize),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const shared_step = b.step("shared", "Build and install the shared library for C, Python, and Node.js consumers");
    shared_step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const aq_core_test_step = b.step("aq-core-test", "Run src-aq-core embedded SurrealDB tests");
    aq_core_test_step.dependOn(&run_aq_core_tests.step);
}
