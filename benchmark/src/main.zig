const std = @import("std");
const mustache = @import("mustache");

pub fn main() anyerror!void {
    try runParseAndAlloc();
    try runCachedAlloc();
    try runParseStream();
    try runCachedStream();
}

const TIMES = 1_000_000;

// Based on https://www.measurethat.net/Benchmarks/Show/817/3/mustache-rendering-performance
const template = "<strong>This is a slightly more complicated {{thing}}.</strong>.\n{{! Just ignore this business. }}\nCheck this out:\n{{#hasThings}}\n<ul>\n{{#things}}\n<li class={{className}}>{{word}}</li>\n{{/things}}</ul>.\n{{/hasThings}}\n{{^hasThings}}\n\n<small>Nothing to check out...</small>\n{{/hasThings}}";

// On the original benchmark, this context has a function
// It's not supported yet
var context = .{
    .thing = "blah",
    .things = .{
        .{ .className = "one", .word = "@fat" },
        .{ .className = "two", .word = "@dhg" },
        .{ .className = "three", .word = "@sayrer" },
    },
    .hasThings = true,
};

fn runParseAndAlloc() !void {
    const allocator = std.heap.raw_c_allocator;

    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.renderAllocFromString(allocator, template, context);
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary("Parse and alloc", ellapsed);
}

fn runCachedAlloc() !void {
    const allocator = std.heap.raw_c_allocator;

    const cached_template = switch (try mustache.loadCachedTemplate(allocator, template, .{}, false)) {
        .ParseError => |last_error| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(last_error.error_code), last_error.lin, last_error.col });
            return;
        },
        .Success => |ret| ret,
    };

    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.renderAllocCached(allocator, cached_template, context);
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary("Cached and alloc", ellapsed);
}

fn runParseStream() !void {
    const allocator = std.heap.raw_c_allocator;

    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        try mustache.renderFromString(allocator, template, context, std.io.null_writer);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary("Parse stream", ellapsed);
}

fn runCachedStream() !void {
    const allocator = std.heap.raw_c_allocator;

    const cached_template = switch (try mustache.loadCachedTemplate(allocator, template, .{}, false)) {
        .ParseError => |last_error| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(last_error.error_code), last_error.lin, last_error.col });
            return;
        },
        .Success => |ret| ret,
    };

    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        try mustache.renderCached(allocator, cached_template, context, std.io.null_writer);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary("Cached stream", ellapsed);
}

fn printSummary(caption: []const u8, ellapsed: i128) void {
    std.debug.print("\n{s}", .{caption});
    std.debug.print("Total time {d:.3}ms\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_s});
    std.debug.print("Total per item {d:.5}ms\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_ms / TIMES});
    std.debug.print("Ops per second {d:.3}\n", .{TIMES / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
}
