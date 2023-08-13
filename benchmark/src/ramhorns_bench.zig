// Bench suite based on Ramhorns benchmarkw
// https://github.com/maciejhirsz/ramhorns/tree/master/tests/benches

const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache");
const TIMES = if (builtin.mode == .Debug) 10_000 else 1_000_000;

// Run tests on full featured mustache specs, or minimum settings for the use case
const full = true;
const features: mustache.options.Features = if (full) .{} else .{
    .preseve_line_breaks_and_indentation = false,
    .lambdas = .disabled,
};

const Mode = enum {
    Buffer,
    Alloc,
    Writer,
};

pub fn main() anyerror!void {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var file = try tmp_dir.dir.createFile("test.mustache", .{ .truncate = true });
    defer file.close();

    var file_writer = std.io.bufferedWriter(file.writer());
    defer file_writer.flush() catch unreachable;
    var buffer: [1024]u8 = undefined;

    if (builtin.mode == .Debug) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        const allocator = gpa.allocator();
        try simpleTemplate(allocator, &buffer, .Buffer, std.io.null_writer);
        try simpleTemplate(allocator, &buffer, .Alloc, std.io.null_writer);
        try simpleTemplate(allocator, &buffer, .Writer, file_writer);
        try partialTemplates(allocator, &buffer, .Buffer, std.io.null_writer);
        try partialTemplates(allocator, &buffer, .Alloc, std.io.null_writer);
        try parseTemplates(allocator);
    } else {
        const allocator = std.heap.c_allocator;

        try simpleTemplate(allocator, &buffer, .Buffer, std.io.null_writer);
        try simpleTemplate(allocator, &buffer, .Alloc, std.io.null_writer);
        try simpleTemplate(allocator, &buffer, .Writer, file_writer);
        try partialTemplates(allocator, &buffer, .Buffer, std.io.null_writer);
        try partialTemplates(allocator, &buffer, .Alloc, std.io.null_writer);
        try parseTemplates(allocator);
    }
}

pub fn simpleTemplate(allocator: Allocator, buffer: []u8, comptime mode: Mode, writer: anytype) !void {
    const template_text = "<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>";
    const fmt_template = "<title>{[title]s}</title><h1>{[title]s}</h1><div>{[body]s}</div>";

    const Data = struct { title: []const u8, body: []const u8 };
    var data: Data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var json_text = try std.json.stringifyAlloc(allocator, data, .{});
    defer allocator.free(json_text);

    var json_data = try std.json.parseFromSlice(std.json.Value, json_text, .{});
    defer json_data.deinit();

    var template = (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false, .features = features })).success;
    defer template.deinit(allocator);

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});
    const reference = try repeat("Reference: Zig fmt", zigFmt, .{
        allocator,
        buffer,
        mode,
        fmt_template,
        data,
        writer,
    }, null);

    _ = try repeat(
        "Mustache pre-parsed",
        preParsed,
        .{
            allocator,
            buffer,
            mode,
            template,
            data,
            writer,
        },
        reference,
    );

    _ = try repeat(
        "Mustache pre-parsed - JSON",
        preParsed,
        .{
            allocator,
            buffer,
            mode,
            template,
            json_data,
            writer,
        },
        reference,
    );

    if (mode != .Buffer) _ = try repeat(
        "Mustache not parsed",
        notParsed,
        .{
            allocator,
            buffer,
            mode,
            template_text,
            data,
            writer,
        },
        reference,
    );

    if (mode != .Buffer) _ = try repeat(
        "Mustache not parsed - JSON",
        notParsed,
        .{
            allocator,
            buffer,
            mode,
            template_text,
            data,
            writer,
        },
        reference,
    );

    std.debug.print("\n\n", .{});
}

pub fn partialTemplates(allocator: Allocator, buffer: []u8, comptime mode: Mode, writer: anytype) !void {
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

    const partial_templates_text = [_]struct { []const u8, []const u8 }{
        .{ "head.html", head_partial_text },
        .{ "footer.html", footer_partial_text },
    };

    const Data = struct { title: []const u8, body: []const u8 };
    var data: Data = .{
        .title = "Hello, Mustache!",
        .body = "This is a really simple test of the rendering!",
    };

    var json_text = try std.json.stringifyAlloc(allocator, data, .{});
    defer allocator.free(json_text);

    var json_data = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer json_data.deinit();

    std.debug.print("Mode {s}\n", .{@tagName(mode)});
    std.debug.print("----------------------------------\n", .{});

    _ = try repeat(
        "Mustache pre-parsed partials",
        preParsedPartials,
        .{
            allocator,
            buffer,
            mode,
            template,
            partial_templates,
            data,
            writer,
        },
        null,
    );

    _ = try repeat(
        "Mustache pre-parsed partials - JSON",
        preParsedPartials,
        .{
            allocator,
            buffer,
            mode,
            template,
            partial_templates,
            json_data,
            writer,
        },
        null,
    );

    if (mode != .Buffer) _ = try repeat(
        "Mustache not parsed partials",
        notParsedPartials,
        .{
            allocator,
            buffer,
            mode,
            template_text,
            partial_templates_text,
            data,
            writer,
        },
        null,
    );

    if (mode != .Buffer) _ = try repeat(
        "Mustache not parsed partials - JSON",
        notParsedPartials,
        .{
            allocator,
            buffer,
            mode,
            template_text,
            partial_templates_text,
            json_data,
            writer,
        },
        null,
    );

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
        total_bytes += try @call(.auto, func, args);
    }
    const ellapsed = std.time.nanoTimestamp() - start;

    printSummary(caption, ellapsed, total_bytes, reference);
    return ellapsed;
}

fn printSummary(caption: []const u8, ellapsed: i128, total_bytes: usize, reference: ?i128) void {
    std.debug.print("{s}\n", .{caption});
    std.debug.print("Total time {d:.3}s\n", .{@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s});

    if (reference) |reference_time| {
        const perf = if (reference_time > 0) @as(f64, @floatFromInt(ellapsed)) / @as(f64, @floatFromInt(reference_time)) else 0;
        std.debug.print("Comparation {d:.3}x {s}\n", .{ perf, (if (perf > 0) "slower" else "faster") });
    }

    std.debug.print("{d:.0} ops/s\n", .{TIMES / (@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s)});
    std.debug.print("{d:.0} ns/iter\n", .{@as(f64, @floatFromInt(ellapsed)) / TIMES});
    std.debug.print("{d:.0} MB/s\n", .{(@as(f64, @floatFromInt(total_bytes)) / 1024 / 1024) / (@as(f64, @floatFromInt(ellapsed)) / std.time.ns_per_s)});
    std.debug.print("\n", .{});
}

fn zigFmt(allocator: Allocator, buffer: []u8, mode: Mode, comptime fmt_template: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Buffer => {
            const ret = try std.fmt.bufPrint(buffer, fmt_template, data);
            return ret.len;
        },
        .Writer => {
            var counter = std.io.countingWriter(writer);
            try std.fmt.format(counter.writer(), fmt_template, data);
            return counter.bytes_written;
        },
        .Alloc => {
            const ret = try std.fmt.allocPrint(allocator, fmt_template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsed(allocator: Allocator, buffer: []u8, mode: Mode, template: mustache.Template, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Buffer => {
            const ret = try mustache.bufRender(buffer, template, data);
            return ret.len;
        },
        .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.render(template, data, counter.writer());
            return counter.bytes_written;
        },
        .Alloc => {
            const ret = try mustache.allocRender(allocator, template, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn preParsedPartials(allocator: Allocator, buffer: []u8, mode: Mode, template: mustache.Template, partial_templates: anytype, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Buffer => {
            var ret = try mustache.bufRenderPartials(buffer, template, partial_templates, data);
            return ret.len;
        },
        .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderPartials(template, partial_templates, data, counter.writer());
            return counter.bytes_written;
        },
        .Alloc => {
            const ret = try mustache.allocRenderPartials(allocator, template, partial_templates, data);
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsed(allocator: Allocator, buffer: []u8, mode: Mode, template_text: []const u8, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Buffer => {
            _ = buffer;
            return 0;
        },
        .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderTextPartialsWithOptions(allocator, template_text, {}, data, counter.writer(), .{ .features = features });
            return counter.bytes_written;
        },
        .Alloc => {
            const ret = try mustache.allocRenderTextPartialsWithOptions(allocator, template_text, {}, data, .{ .features = features });
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn notParsedPartials(allocator: Allocator, buffer: []u8, mode: Mode, template_text: []const u8, partial_templates: anytype, data: anytype, writer: anytype) !usize {
    switch (mode) {
        .Buffer => {
            _ = buffer;
            return 0;
        },
        .Writer => {
            var counter = std.io.countingWriter(writer);
            try mustache.renderTextPartialsWithOptions(allocator, template_text, partial_templates, data, counter.writer(), .{ .features = features });
            return counter.bytes_written;
        },
        .Alloc => {
            const ret = try mustache.allocRenderTextPartialsWithOptions(allocator, template_text, partial_templates, data, .{ .features = features });
            defer allocator.free(ret);
            return ret.len;
        },
    }
}

fn parse(allocator: Allocator) !usize {
    const template_text =
        \\<html>
        \\    <head>
        \\        <title>{{title}}</title>
        \\    </head>
        \\    <body>
        \\        {{#posts}}
        \\            <h1>{{title}}</h1>
        \\            <em>{{date}}</em>
        \\            <article>
        \\                {{{body}}}
        \\            </article>
        \\        {{/posts}}
        \\    </body>
        \\</html>
    ;

    var template = switch (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false, .features = features })) {
        .success => |template| template,
        else => unreachable,
    };

    template.deinit(allocator);
    return template_text.len;
}
