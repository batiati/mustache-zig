const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_model = .baseline,
        },
    });

    // Benchmark defaults to ReleaseSafe
    const mode = std.builtin.OptimizeMode.ReleaseSafe;

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = .{ .path = "src/ramhorns_bench.zig" },
        .target = target,
        .optimize = mode,
    });

    exe.addAnonymousModule("mustache", .{
        .source_file = .{ .path = "../src/mustache.zig" },
    });
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
