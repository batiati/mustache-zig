const std = @import("std");
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const mustache = @import("mustache");

// Mustache template
const template_text =
    \\{{! This is a spec-compliant mustache template }}
    \\Hello {{name}} from Zig
    \\This template was generated with
    \\{{#env}}
    \\Zig: {{zig_version}}
    \\Mustache: {{mustache_version}}
    \\{{/env}}
    \\Supported features:
    \\{{#features}}
    \\  - {{name}} {{condition}}
    \\{{/features}}
;

// Context, can be any Zig struct, supporting optionals, slices, tuples, recursive types, pointers, etc.
var ctx = .{
    .name = "friends",
    .env = .{
        .zig_version = "master",
        .mustache_version = "alpha",
    },
    .features = .{
        .{ .name = "interpolation", .condition = "done" },
        .{ .name = "sections", .condition = "done" },
        .{ .name = "comments", .condition = "done" },
        .{ .name = "delimiters", .condition = "done" },
        .{ .name = "partials", .condition = "comming soon" },
        .{ .name = "inheritance", .condition = "comming soon" },
        .{ .name = "functions", .condition = "comming soon" },
    },
};

pub fn main() anyerror!void {
    try renderFromString();
    try renderFromCachedTemplate();
    try renderFromFile();
}

///
/// Cache a template to render many times
pub fn renderFromCachedTemplate() anyerror!void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Store this template and render many times from it
    const cached_template = switch (try mustache.parse(allocator, template_text, .{}, false)) {
        .ParseError => |detail| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            return;
        },
        .Success => |ret| ret,
    };

    var repeat: u32 = 0;
    while (repeat < 10) : (repeat += 1) {
        var result = try mustache.allocRender(allocator, cached_template, ctx);
        defer allocator.free(result);

        var out = std.io.getStdOut();
        try out.writeAll(result);
    }
}

///
/// Render a template from a string
pub fn renderFromString() anyerror!void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var out = std.io.getStdOut();

    // Direct render to save memory
    try mustache.renderFromString(allocator, template_text, ctx, out.writer());
}

///
/// Render a template from a file path
pub fn renderFromFile() anyerror!void {

    // 16KB should be enough memory for this job
    var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
        .requested_memory_limit = 16 * 1024,
    };
    defer _ = plenty_of_memory.deinit();

    const allocator = plenty_of_memory.allocator();

    const path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(path);

    // Creating a temp file
    const path_to_template = try std.fs.path.join(allocator, &.{ path, "template.mustache" });
    defer allocator.free(path_to_template);
    defer std.fs.deleteFileAbsolute(path_to_template) catch {};

    {
        var file = try std.fs.createFileAbsolute(path_to_template, .{ .truncate = true });
        defer file.close();
        var repeat: u32 = 0;

        // Writing the same template 10K times on a file
        while (repeat < 10_000) : (repeat += 1) {
            try file.writeAll(template_text);
        }
    }

    var out = std.io.getStdOut();

    // Rendering this large template with only 16KB of RAM
    try mustache.renderFromFile(allocator, path_to_template, ctx, out.writer());
}
