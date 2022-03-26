// Bench suite based on Ramhorns benchmarkw
// https://github.com/maciejhirsz/ramhorns/tree/master/tests/benches

const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache");
const TIMES = 1_000_000;

pub fn main() anyerror!void {
    try simpleTemplate(std.heap.c_allocator);
}

pub fn simpleTemplate(allocator: Allocator) !void {
    const template_text = "<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>";
    const fmt_template = "<title>{[title]s}</title><h1>{[title]s}</h1><div>{[body]s}</div>";

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var template = (try mustache.parseTemplate(allocator, template_text, .{}, false)).Success;

    try repeat("Zig fmt", zigFmt, .{ allocator, fmt_template, data });
    try repeat("Mustache pre-parsed", preParsed, .{ allocator, template, data });
    try repeat("Mustache not parsed", notParsed, .{ allocator, template_text, data });
}

fn repeat(comptime caption: []const u8, comptime func: anytype, args: anytype) !void {
    var index: usize = 0;
    var total_bytes: usize = 0;

    const start = std.time.nanoTimestamp();
    while (index < TIMES) : (index += 1) {
        total_bytes += try @call(.{}, func, args);
    }
    const end = std.time.nanoTimestamp();

    printSummary(caption, end - start, total_bytes);
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize) void {
    std.debug.print("\n{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_s});
    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@intToFloat(f64, ellapsed) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@intToFloat(f64, total_bytes) / 1024 / 1024) / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
}

fn zigFmt(allocator: Allocator, comptime fmt_template: []const u8, data: anytype) !usize {
    const ret = try std.fmt.allocPrint(allocator, fmt_template, data);
    return ret.len;
}

fn preParsed(allocator: Allocator, template: mustache.Template, data: anytype) !usize {
    const ret = try mustache.renderAllocCached(allocator, template, data);
    return ret.len;
}

fn notParsed(allocator: Allocator, template_text: []const u8, data: anytype) !usize {
    const ret = try mustache.renderAllocFromString(allocator, template_text, data);
    return ret.len;
}
