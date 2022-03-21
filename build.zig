const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();

    {
        const lib = b.addStaticLibrary("mustache", "src/mustache.zig");
        lib.setBuildMode(mode);
        lib.install();
    }

    {
        const main_tests = b.addTest("src/mustache.zig");
        main_tests.setBuildMode(mode);

        const coverage = b.option(bool, "test-coverage", "Generate test coverage") orelse false;

        if (coverage) {

            // with kcov
            main_tests.setExecCmd(&[_]?[]const u8{
                "kcov",
                "--exclude-pattern",
                "lib/std",
                "kcov-output",
                null, // to get zig to use the --test-cmd-bin flag
            });
        }

        const test_step = b.step("test", "Run library tests");
        test_step.dependOn(&main_tests.step);
    }

    {
        const test_exe = b.addTestExe("tests", "src/mustache.zig");
        test_exe.setBuildMode(mode);
        const test_exe_install = b.addInstallArtifact(test_exe);

        const test_build = b.step("build_tests", "Build library tests");
        test_build.dependOn(&test_exe_install.step);
    }
}
