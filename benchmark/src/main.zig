const std = @import("std");
const Allocator = std.mem.Allocator;
const mustache = @import("mustache");

pub fn main() anyerror!void {
    std.debug.print("Benchmark\n{s}\n", .{"https://github.com/batiati/mustache_benchmark"});
    std.debug.print("=============================\n\n", .{});
    try runTemplate("Template 1", Binding1, "data/template1.html", "data/bindings1.json");
    try runTemplate("Template 2", Binding2, "data/template2.html", "data/bindings2.json");
    try runTemplate("Template 3", Binding3, "data/template3.html", "data/bindings3.json");
}

const TIMES = 1_000_000;

const Binding1 = struct {
    title: []const u8,
    txt1: []const u8,
    txt2: []const u8,
    txt3: []const u8,
};

const Binding2 = struct {
    title: []const u8,
    image_url: []const u8,
    icon_url: []const u8,
    short_description: []const u8,
    detail_description: []const u8,
    offer_id: u32,
};

const Binding3 = struct {
    const Repo = struct { name: []const u8 };

    name: []const u8,
    age: u32,
    company: []const u8,
    person: bool,
    repo: []const Repo,
    repo2: []const Repo,
};

fn runTemplate(comptime caption: []const u8, comptime TBinding: type, comptime template: []const u8, comptime json: []const u8) !void {
    const template_text = @embedFile(template);

    const allocator = std.heap.c_allocator;

    var cached_template = parseTemplate(allocator, template_text);
    defer cached_template.deinit(allocator);

    try runTemplatePreParsed(allocator, caption ++ " - pre-parsed", TBinding, @embedFile(json), cached_template);
    try runTemplateNotParsed(allocator, caption ++ " - not parsed", TBinding, @embedFile(json), template_text);
}

fn runTemplatePreParsed(allocator: Allocator, comptime caption: []const u8, comptime TBinding: type, comptime json: []const u8, template: mustache.Template) !void {
    var data = try std.json.parseFromSlice(TBinding, allocator, json, .{});
    defer data.deinit();

    var total_bytes: usize = 0;
    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.allocRender(allocator, template, &data.value);
        total_bytes += result.len;
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary(caption, ellapsed, total_bytes);
}

fn runTemplateNotParsed(allocator: Allocator, comptime caption: []const u8, comptime TBinding: type, comptime json: []const u8, comptime template_text: []const u8) !void {
    var data = try std.json.parseFromSlice(TBinding, allocator, json, .{});
    defer data.deinit();

    var total_bytes: usize = 0;
    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.allocRenderText(allocator, template_text, &data.value);
        total_bytes += result.len;
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary(caption, ellapsed, total_bytes);
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize) void {
    std.debug.print("\n{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s});
    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@as(f64, @floatFromInt(ellapsed)) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@as(f64, @floatFromInt(total_bytes)) / 1024 / 1024) / (@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s)});
}

fn parseTemplate(allocator: Allocator, template_text: []const u8) mustache.Template {
    return switch (mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false }) catch unreachable) {
        .parse_error => |detail| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            @panic("parser error");
        },
        .success => |ret| ret,
    };
}
