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
    Writer,
};

pub fn main() anyerror!void {
    var file = try std.fs.openFileAbsolute("/dev/null", .{ .mode = .write_only });
    defer file.close();

    if (builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        const allocator = gpa.allocator();
        try simpleTemplate(allocator, .Counter, std.io.null_writer);
        try simpleTemplate(allocator, .String, std.io.null_writer);
        try simpleTemplate(allocator, .Writer, file.writer());
        try partialTemplates(allocator, .Counter, std.io.null_writer);
        try partialTemplates(allocator, .String, std.io.null_writer);
        try parseTemplates(allocator);
    } else {
        const allocator = std.heap.raw_c_allocator;

        try simpleTemplate(allocator, .Counter, std.io.null_writer);
        try simpleTemplate(allocator, .String, std.io.null_writer);
        try simpleTemplate(allocator, .Writer, file.writer());
        try partialTemplates(allocator, .Counter, std.io.null_writer);
        try partialTemplates(allocator, .String, std.io.null_writer);
        try parseTemplates(allocator);
    }
}

// Run tests on full featured mustache specs, or minimum settings for the use case
const full = true;
const features: mustache.options.Features = if (full)
.{} else .{
    .preseve_line_breaks_and_indentation = false,
    .lambdas = .Disabled,
};

pub fn simpleTemplate(allocator: Allocator, comptime mode: Mode, writer: anytype) !void {
    const template_text = "<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>";
    const fmt_template = "<title>{s}</title><h1>{s}</h1><div>{s}</div>";

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var template = (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false, .features = features })).success;
    defer template.deinit(allocator);

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    const reference = try repeat("Reference: Zig fmt", zigFmt, .{
        allocator,
        mode,
        fmt_template,
        .{ data.title, data.title, data.body },
        writer,
    }, null);
    _ = try repeat("Mustache pre-parsed", preParsed, .{ allocator, mode, template, data, writer }, reference);
    _ = try repeat("Mustache not parsed", notParsed, .{ allocator, mode, template_text, data, writer }, reference);
    std.debug.print("\n\n", .{});
}

pub fn partialTemplates(allocator: Allocator, comptime mode: Mode, writer: anytype) !void {
    const template_text =
        \\{{>head.html}}
        \\<body>
        \\    <div>{{body}}</div>
        \\    {{>footer.html}}
        \\</body>
    ;

    const head_partial_text =
        \\<head>
        \\    <title>{{title}}</title>
        \\</head>
    ;

    const footer_partial_text = "<footer>Sup?</footer>";

    var template = (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false, .features = features })).success;
    defer template.deinit(allocator);

    var head_template = (try mustache.parseText(allocator, head_partial_text, .{}, .{ .copy_strings = false, .features = features })).success;
    defer head_template.deinit(allocator);

    var footer_template = (try mustache.parseText(allocator, footer_partial_text, .{}, .{ .copy_strings = false, .features = features })).success;
    defer footer_template.deinit(allocator);

    var partial_templates = std.StringHashMap(mustache.Template).init(allocator);
    defer partial_templates.deinit();

    try partial_templates.put("head.html", head_template);
    try partial_templates.put("footer.html", footer_template);

    const partial_templates_text = .{
        .{ "head.html", head_partial_text },
        .{ "footer.html", footer_partial_text },
    };

    var data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    _ = try repeat("Mustache pre-parsed partials", preParsedPartials, .{ allocator, mode, template, partial_templates, data, writer }, null);
    _ = try repeat("Mustache not parsed partials", notParsedPartials, .{ allocator, mode, template_text, partial_templates_text, data, writer }, null);
    std.debug.print("\n\n", .{});
}

pub fn parseTemplates(allocator: Allocator) !void {
    std.debug.print("----------------------------------\n", .{});
    _ = try repeat("Parse", parse, .{allocator}, null);
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

fn zigFmt(allocator: Allocator, mode: Mode, comptime fmt_template: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
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

fn preParsed(allocator: Allocator, mode: Mode, template: mustache.Template, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.render(template, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRender(allocator, template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsedPartials(allocator: Allocator, mode: Mode, template: mustache.Template, partial_templates: anytype, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderPartials(template, partial_templates, data, counter.writer());
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRenderPartials(allocator, template, partial_templates, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsed(allocator: Allocator, mode: Mode, template_text: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderTextPartialsWithOptions(allocator, template_text, {}, data, counter.writer(), .{ .features = features });
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRenderTextPartialsWithOptions(allocator, template_text, {}, data, .{ .features = features });
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsedPartials(allocator: Allocator, mode: Mode, template_text: []const u8, partial_templates: anytype, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Counter, .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderTextPartialsWithOptions(allocator, template_text, partial_templates, data, counter.writer(), .{ .features = features });
            return counter.bytes_written;
        },
        .String => {
            const ret = try mustache.allocRenderTextPartialsWithOptions(allocator, template_text, partial_templates, data, .{ .features = features });
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn parse(allocator: Allocator) !usize {
    const template_text =
        \\<html>\
        \\    <head>\
        \\        <title>{{title}}</title>\
        \\    </head>
        \\    <body>\
        \\        {{#posts}}\
        \\            <h1>{{title}}</h1>\
        \\            <em>{{date}}</em>\
        \\            <article>\
        \\                {{{body}}}\
        \\            </article>\
        \\        {{/posts}}\
        \\    </body>\
        \\</html>\
    ;

    var template = switch (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false, .features = features })) {
        .success => |template| template,
        else => unreachable,
    };

    template.deinit(allocator);
    return template_text.len;
}
