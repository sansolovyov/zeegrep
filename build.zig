const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string") orelse gitVersion(b);
    const output = b.option([]const u8, "output", "Custom output path (e.g., dist/zg-Linux-x86_64)");

    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    const opt_dep = b.dependency("opt", .{});
    const pcre2_c = b.addTranslateC(.{
        .root_source_file = pcre2_dep.namedLazyPath("pcre2.h"),
        .target = target,
        .optimize = optimize,
    });
    pcre2_c.defineCMacro("PCRE2_CODE_UNIT_WIDTH", "8");
    const pcre2_module = pcre2_c.createModule();

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = &.{
            .{ .name = "opt", .module = opt_dep.module("opt") },
            .{ .name = "pcre2", .module = pcre2_module },
        },
    });
    exe_module.addOptions("build_options", build_options);
    const exe = b.addExecutable(.{
        .name = "zg",
        .root_module = exe_module,
    });
    exe.root_module.linkLibrary(pcre2_lib);
    if (output) |out_path| {
        const install = b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, out_path);
        b.getInstallStep().dependOn(&install.step);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run zg");
    run_step.dependOn(&run_cmd.step);

    const run_test_module = b.createModule(.{
        .root_source_file = b.path("src/run.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "opt", .module = opt_dep.module("opt") },
            .{ .name = "pcre2", .module = pcre2_module },
        },
    });
    const run_tests = b.addTest(.{ .root_module = run_test_module });
    run_tests.root_module.linkLibrary(pcre2_lib);
    const run_run_tests = b.addRunArtifact(run_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_run_tests.step);
}

fn gitVersion(b: *std.Build) []const u8 {
    b.graph.poisonCache();
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "describe", "--tags", "--always", "--dirty=+" },
        .cwd = .{ .path = b.root.toString(b.allocator) catch return "dev" },
    }) catch return "dev";
    switch (result.term) {
        .exited => |code| if (code != 0) return "dev",
        else => return "dev",
    }
    return std.mem.trimEnd(u8, result.stdout, "\n\r ");
}
