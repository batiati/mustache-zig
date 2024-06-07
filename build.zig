const std = @import("std");
const CrossTarget = std.zig.CrossTarget;

pub fn build(b: *std.Build) void {
    const mode = b.standardOptimizeOption(.{});

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_model = .baseline,
        },
    });

    const ffi_libs = b.step("ffi", "Build FFI libs");

    // Zig cross-target x folder names
    const platforms = .{
        .{ "x86_64-linux-gnu", "linux-x64" },
        .{ "x86_64-windows-gnu", "win-x64" },
        .{ "x86_64-macos", "osx-x64" },
    };

    inline for (platforms) |platform| {
        const cross_target = CrossTarget.parse(.{ .arch_os_abi = platform[0], .cpu_features = "baseline" }) catch unreachable;

        // Appends the name "lib" on windows, in order to generate the same name "libmustache" for all platforms
        const lib_name = comptime (if (std.mem.startsWith(u8, platform[1], "win")) "lib" else "") ++ "mustache";
        const lib_path = "../lib/" ++ platform[1];

        const lib = b.addSharedLibrary(.{
            .name = lib_name,
            .root_source_file = b.path("src/exports.zig"),
            .target = b.resolveTargetQuery(cross_target),
            .optimize = mode,
            .link_libc = true,
        });

        const install_step = b.addInstallArtifact(
            lib,
            .{ .dest_dir = .{
                .override = .{ .custom = lib_path },
            } },
        );
        ffi_libs.dependOn(&install_step.step);
    }

    // Zig module
    _ = b.addModule("mustache", .{ .root_source_file = b.path("src/mustache.zig") });

    // C FFI Sample
    {
        const static_lib = b.addStaticLibrary(.{
            .name = "mustache-static",
            .root_source_file = b.path("src/exports.zig"),
            .target = target,
            .optimize = mode,
            .link_libc = true,
        });

        const c_sample = b.addExecutable(.{
            .name = "sample",
            .root_source_file = null,
            .target = target,
            .optimize = mode,
        });
        c_sample.root_module.addCSourceFile(.{
            .file = b.path("samples/c/sample.c"),
        });
        c_sample.linkLibrary(static_lib);
        c_sample.linkLibC();

        const run_cmd = b.addRunArtifact(c_sample);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const c_sample_build = b.step("c_sample", "Run the C sample");
        c_sample_build.dependOn(&run_cmd.step);
    }

    // Tests

    var comptime_tests = b.addOptions();
    const comptime_tests_enabled = b.option(bool, "comptime-tests", "Run comptime tests") orelse true;
    comptime_tests.addOption(bool, "comptime_tests_enabled", comptime_tests_enabled);

    {
        const filter = b.option(
            []const u8,
            "test-filter",
            "Skip tests that do not match filter",
        );
        if (filter) |filter_value| std.log.debug("filter: {s}", .{filter_value});

        const main_tests = b.addTest(.{
            .name = "tests",
            .root_source_file = b.path("src/mustache.zig"),
            .target = target,
            .optimize = mode,
            .filter = filter,
        });

        main_tests.root_module.addOptions("build_comptime_tests", comptime_tests);
        const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

        const run_main_tests = b.addRunArtifact(main_tests);

        if (coverage) {
            // with kcov
            const kcov = b.addSystemCommand(&.{
                "kcov",    "--exclude-pattern",
                "lib/std", "kcov-output",
            });
            kcov.addArtifactArg(main_tests);

            run_main_tests.step.dependOn(&kcov.step);
        }

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_main_tests.step);
    }

    {
        const test_exe = b.addTest(.{
            .name = "tests",
            .root_source_file = b.path("src/mustache.zig"),
            .target = target,
            .optimize = mode,
        });
        test_exe.root_module.addOptions("build_comptime_tests", comptime_tests);

        const test_exe_install = b.addInstallArtifact(test_exe, .{});

        const test_build = b.step("build_tests", "Build library tests");
        test_build.dependOn(&test_exe_install.step);
    }
}
