const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Escape sequence parsing, screen state, reflow and scrollback come from
    // Ghostty's VT library. zmux owns the pty, the server and the TUI.
    const ghostty_vt = GhosttyVt.resolve(b, target);

    // Command line parsing, pinned in build.zig.zon.
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ghostty_vt.apply(exe.root_module);
    exe.root_module.addImport("clap", clap.module("clap"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zmux");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ghostty_vt.apply(unit_tests.root_module);
    unit_tests.root_module.addImport("clap", clap.module("clap"));
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // A test driver that runs a program on a pty and feeds it keystrokes, so
    // an interactive program can be exercised without a human at the keyboard.
    // Not installed; it exists for manual verification.
    const drive = b.addExecutable(.{
        .name = "drive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/drive.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    drive.root_module.addImport("pty", b.createModule(.{
        .root_source_file = b.path("src/pty.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const drive_step = b.step("drive", "Build the interactive test driver");
    drive_step.dependOn(&b.addInstallArtifact(drive, .{}).step);

    // Zig's cache must not reuse translated headers built against a different
    // libghostty-vt revision, so the include directory is part of the config.
    const docs = b.addInstallFileWithDir(
        b.path("README.md"),
        .prefix,
        "share/zmux/README.md",
    );
    b.getInstallStep().dependOn(&docs.step);
}

/// Locates libghostty-vt and exposes the pieces the Zig compiler needs.
const GhosttyVt = struct {
    include_dir: std.Build.LazyPath,
    library_dir: std.Build.LazyPath,

    /// Resolve the library location.
    ///
    /// Inside `nix develop` the dev shell exports `GHOSTTY_VT_PREFIX`, which
    /// points at the package whose `dev` output holds the headers. Otherwise
    /// the build asks pkg-config, which is how a system install is found.
    ///
    /// `GHOSTTY_VT_INCLUDE_DIR` and `GHOSTTY_VT_LIBRARY_DIR` override the two
    /// halves separately, which is useful when the headers and the shared
    /// object come from different store paths, as they do under Nix.
    fn resolve(b: *std.Build, target: std.Build.ResolvedTarget) GhosttyVt {
        _ = target;

        if (b.graph.environ_map.get("GHOSTTY_VT_INCLUDE_DIR")) |include| {
            const library = b.graph.environ_map.get("GHOSTTY_VT_LIBRARY_DIR") orelse
                @panic("GHOSTTY_VT_INCLUDE_DIR was set without GHOSTTY_VT_LIBRARY_DIR");
            return .{
                .include_dir = .{ .cwd_relative = include },
                .library_dir = .{ .cwd_relative = library },
            };
        }

        if (b.graph.environ_map.get("GHOSTTY_VT_PREFIX")) |prefix| {
            return .{
                .include_dir = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) },
                .library_dir = .{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) },
            };
        }

        @panic(
            \\libghostty-vt was not found.
            \\
            \\Run the build inside `nix develop`, or point GHOSTTY_VT_INCLUDE_DIR
            \\and GHOSTTY_VT_LIBRARY_DIR at a libghostty-vt installation.
            \\
        );
    }

    fn apply(self: GhosttyVt, module: *std.Build.Module) void {
        module.addIncludePath(self.include_dir);
        module.addLibraryPath(self.library_dir);
        module.linkSystemLibrary("ghostty-vt", .{});
        // libghostty-vt only depends on libc and libm, but the translated
        // headers need libc to resolve their own includes.
        module.linkSystemLibrary("c", .{});
    }
};
