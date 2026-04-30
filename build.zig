const std = @import("std");

const adbc_include_dir = "third_party/adbc/1.11.0/include";

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
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "database_zig",
        .root_module = makeCAbiModule(b, target, optimize),
    });

    b.installArtifact(shared_lib);
    b.installFile("bindings/c/include/database_zig.h", "include/database_zig.h");

    const unit_tests = b.addTest(.{
        .root_module = makeModule(b, target, optimize),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const shared_step = b.step("shared", "Build and install the shared library for C, Python, and Node.js consumers");
    shared_step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
