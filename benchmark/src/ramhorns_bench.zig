// Bench suite based on Ramhorns benchmarkw
// https://github.com/maciejhirsz/ramhorns/tree/master/tests/benches

const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache");
const TIMES = if (builtin.mode == .Debug) 10_000 else 1_000_000;

const Mode = enum {
    Counter,
    String,
};

pub fn main() anyerror!void {
    if (builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        try simpleTemplate(gpa.allocator(), .Counter);
        try simpleTemplate(gpa.allocator(), .String);
    } else {
        try simpleTemplate(std.heap.raw_c_allocator, .Counter);
        try simpleTemplate(std.heap.raw_c_allocator, .String);
    }
}

pub fn simpleTemplate(allocator: Allocator, comptime mode: Mode) !void {
    const template_text = "<title>{{&title}}</title><h1>{{&title}}</h1><div>{{{body}}}</div>";
    const fmt_template = "<title>{s}</title><h1>{s}</h1><div>{s}</div>";

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var template = (try mustache.parseTemplate(allocator, template_text, .{}, false)).Success;
    defer template.free(allocator);

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    const reference = try repeat("Reference: Zig fmt", zigFmt, .{
        allocator,
        mode,
        fmt_template,
        .{ data.title, data.title, data.body },
    }, null);
    _ = try repeat("Mustache pre-parsed", preParsed, .{ allocator, mode, template, data }, reference);
    _ = try repeat("Mustache not parsed", notParsed, .{ allocator, mode, template_text, data }, reference);
    std.debug.print("\n\n", .{});
}

fn repeat(comptime caption: []const u8, comptime func: anytype, args: anytype, reference: ?i128) !i128 {
    var index: usize = 0;
    var total_bytes: usize = 0;

    const start = std.time.nanoTimestamp();
    while (index < TIMES) : (index += 1) {
        total_bytes += try @call(.{}, func, args);
    }
    const ellapsed = std.time.nanoTimestamp() - start;

    printSummary(caption, ellapsed, total_bytes, reference);
    return ellapsed;
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize, reference: ?i128) void {
    std.debug.print("{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_s});

    if (reference) |reference_time| {
        const perf = if (reference_time > 0) @intToFloat(f64, ellapsed) / @intToFloat(f64, reference_time) else 0;
        std.debug.print("Comparation {d:.3}x {s}\n", .{ perf, (if (perf > 0) "slower" else "faster") });
    }

    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@intToFloat(f64, ellapsed) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@intToFloat(f64, total_bytes) / 1024 / 1024) / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("\n", .{});
}

fn zigFmt(allocator: Allocator, mode: Mode, comptime fmt_template: []const u8, data: anytype) !usize {
    switch (mode) {
        .Counter => {
            var counter = std.io.countingWriter(std.io.null_writer);
            try std.fmt.format(counter.writer(), fmt_template, data);
            return counter.bytes_written;
        },
        .String => {
            const ret = try std.fmt.allocPrint(allocator, fmt_template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsed(allocator: Allocator, mode: Mode, template: mustache.Template, data: anytype) !usize {
    switch (mode) {
        .Counter => {
            var counter = std.io.countingWriter(std.io.null_writer);
            try mustache.render(template, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.renderAlloc(allocator, template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsed(allocator: Allocator, mode: Mode, template_text: []const u8, data: anytype) !usize {
    switch (mode) {
        .Counter => {
            var counter = std.io.countingWriter(std.io.null_writer);
            try mustache.renderFromString(allocator, template_text, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.renderAllocFromString(allocator, template_text, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}
