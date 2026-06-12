const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{
        .simd = false,
        .@"emit-xcframework" = false,
        // lib-vt-only build: without this, ghostty's build graph wires
        // up its full exe and probes for the Darwin SDK at configure
        // time, which fails inside the nix build sandbox.
        .@"emit-lib-vt" = true,
    })) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    if (b.lazyDependency("jsonc", .{})) |dep| {
        exe_mod.addImport("jsonc", dep.module("jsonc"));
    }

    const exe = b.addExecutable(.{
        .name = "zmux",
        .root_module = exe_mod,
    });

    exe.linkLibC();
    // macOS libc requires dynamic linking; static linkage is Linux-only.
    if (target.result.os.tag == .linux) {
        exe.linkage = .static;
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
