const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_model = .baseline,
        },
    });

    // Benchmark defaults to ReleaseSafe
    const mode = std.builtin.Mode.ReleaseSafe;

    const exe = b.addExecutable("benchmark", "src/ramhorns_bench.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("mustache", "../src/mustache.zig");
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);
}
