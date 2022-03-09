const std = @import("std");
const Allocator = std.mem.Allocator;
const mustache = @import("mustache");

pub fn main() anyerror!void {

    std.debug.print("Benchmark\n{s}\n", .{ "https://github.com/batiati/mustache_benchmark" });
    std.debug.print("=============================\n\n", .{});
    try runTemplate("Template 1", Binding1, "../data/template1.html", "../data/bindings1.json");
    try runTemplate("Template 2", Binding2, "../data/template2.html", "../data/bindings2.json");
    try runTemplate("Template 3", Binding3, "../data/template3.html", "../data/bindings3.json");
}

const TIMES = 1_000_000;

const Binding1 = struct {
    title: []const u8,
    txt1: []const u8,
    txt2: []const u8,
    txt3: []const u8,

    pub fn free(self: *Binding1, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.txt1);
        allocator.free(self.txt2);
        allocator.free(self.txt3);
    }
};

const Binding2 = struct {
    title: []const u8,
    image_url: []const u8,
    icon_url: []const u8,
    short_description: []const u8,
    detail_description: []const u8,
    offer_id: u32,

    pub fn free(self: *Binding2, allocator: Allocator) void {
        allocator.free(self.title);
        allocator.free(self.image_url);
        allocator.free(self.icon_url);
        allocator.free(self.short_description);
        allocator.free(self.detail_description);
    }
};

const Binding3 = struct {
    const Repo = struct { name: []const u8 };

    name: []const u8,
    age: u32,
    company: []const u8,
    person: bool,
    repo: []const Repo,
    repo2: []const Repo,

    pub fn free(self: *Binding3, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.company);
        for (self.repo) |item| {
            allocator.free(item.name);    
        }

        for (self.repo2) |item| {
            allocator.free(item.name);    
        }

        allocator.free(self.repo);
        allocator.free(self.repo2);
    }    
};

fn runTemplate(comptime caption: []const u8, comptime TBinding: type, comptime template: []const u8, comptime json: []const u8) !void {
    const template_text = @embedFile(template);

    const allocator = std.heap.c_allocator;
    
    var cached_template = parseTemplate(allocator, template_text);
    defer cached_template.free(allocator);

    try runTemplatePreParsed(allocator, caption ++ " - pre-parsed", TBinding, json, cached_template);
    try runTemplateNotParsed(allocator, caption ++ " - not parsed", TBinding, json, template_text);
}

fn runTemplatePreParsed(allocator: Allocator, comptime caption: []const u8, comptime TBinding: type, comptime json: []const u8, template: mustache.CachedTemplate) !void {

    var data = try loadData(TBinding, allocator, json);
    defer data.free(allocator);

    var total_bytes: usize = 0;
    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.renderAllocCached(allocator, template, data);
        total_bytes += result.len;
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary(caption, ellapsed, total_bytes);
}

fn runTemplateNotParsed(allocator: Allocator, comptime caption: []const u8, comptime TBinding: type, comptime json: []const u8, comptime template_text: []const u8) !void {

    var data = try loadData(TBinding, allocator, json);
    defer data.free(allocator);

    var total_bytes: usize = 0;
    var repeat: u32 = 0;
    const start = std.time.nanoTimestamp();
    while (repeat < TIMES) : (repeat += 1) {
        const result = try mustache.renderAllocFromString(allocator, template_text, data);
        total_bytes += result.len;
        allocator.free(result);
    }
    const end = std.time.nanoTimestamp();

    const ellapsed = end - start;
    printSummary(caption, ellapsed, total_bytes);
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize) void {
    std.debug.print("\n{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@intToFloat(f64, ellapsed) / std.time.ns_per_s});
    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@intToFloat(f64, ellapsed) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@intToFloat(f64, ellapsed) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@intToFloat(f64,total_bytes) / 1024 / 1024) / (@intToFloat(f64, ellapsed) / std.time.ns_per_s) });

    
}

fn parseTemplate(allocator: Allocator, template_text: []const u8) mustache.CachedTemplate {
    return switch (mustache.parseTemplate(allocator, template_text, .{}, false) catch unreachable) {
        .ParseError => |last_error| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(last_error.error_code), last_error.lin, last_error.col });
            @panic("parser error");
        },
        .Success => |ret| ret,
    };
}

fn loadData(comptime T: type, allocator: Allocator, comptime json: []const u8) !T {
    var token_stream = std.json.TokenStream.init(@embedFile(json));
    return try std.json.parse(T, &token_stream, .{ .allocator = allocator });
}
