const std = @import("std");
const meta = std.meta;
const trait = meta.trait;
const Allocator = std.mem.Allocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const TemplateOptions = mustache.options.TemplateOptions;
const RenderTemplateOptions = mustache.options.RenderTemplateOptions;
const RenderTextOptions = mustache.options.RenderTextOptions;
const RenderFileOptions = mustache.options.RenderFileOptions;

const Delimiters = mustache.Delimiters;
const Element = mustache.Element;
const ParseError = mustache.ParseError;
const Template = mustache.Template;

const TemplateLoader = @import("../template.zig").TemplateLoader;

const context = @import("context.zig");
const Escape = context.Escape;

const invoker = @import("invoker.zig");
const Fields = invoker.Fields;

const indent = @import("indent.zig");
const map = @import("partials_map.zig");

const FileError = std.fs.File.OpenError || std.fs.File.ReadError;
const BufError = std.io.FixedBufferStream([]u8).WriteError;

pub const LambdaContext = @import("lambda.zig").LambdaContext;

/// Renders the `Template` with the given `data` to a writer.
pub fn render(template: Template, data: anytype, writer: anytype) !void {
    return try renderPartialsWithOptions(template, {}, data, writer, .{});
}

/// Renders the `Template` with the given `data` to a writer.
pub fn renderWithOptions(template: Template, data: anytype, writer: anytype, comptime options: RenderTemplateOptions) !void {
    return try renderPartialsWithOptions(template, {}, data, writer, options);
}

/// Renders the `Template` with the given `data` to a writer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
pub fn renderPartials(template: Template, partials: anytype, data: anytype, writer: anytype) !void {
    return try renderPartialsWithOptions(template, partials, data, writer, .{});
}

/// Renders the `Template` with the given `data` to a writer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
pub fn renderPartialsWithOptions(template: Template, partials: anytype, data: anytype, writer: anytype, comptime options: RenderTemplateOptions) !void {
    const render_options = RenderOptions{ .Template = options };
    try RenderHelpers.render(template.elements, partials, data, writer, render_options);
}

/// Renders the `Template` with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRender(allocator: Allocator, template: Template, data: anytype) Allocator.Error![]const u8 {
    return try allocRenderPartialsWithOptions(allocator, template, {}, data, .{});
}

/// Renders the `Template` with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderWithOptions(allocator: Allocator, template: Template, data: anytype, comptime options: RenderTemplateOptions) Allocator.Error![]const u8 {
    return try allocRenderPartialsWithOptions(allocator, template, {}, data, options);
}

/// Renders the `Template` with the given `data` to a writer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
/// Caller must free the memory
pub fn allocRenderPartials(allocator: Allocator, template: Template, partials: anytype, data: anytype) Allocator.Error![]const u8 {
    return try allocRenderPartialsWithOptions(allocator, template, partials, data, .{});
}

/// Renders the `Template` with the given `data` to a writer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
/// Caller must free the memory
pub fn allocRenderPartialsWithOptions(allocator: Allocator, template: Template, partials: anytype, data: anytype, comptime options: RenderTemplateOptions) Allocator.Error![]const u8 {
    const render_options = RenderOptions{ .Template = options };
    return try RenderHelpers.allocRender(allocator, template.elements, partials, data, render_options, null);
}

/// Renders the `Template` with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderZ(allocator: Allocator, template: Template, data: anytype) Allocator.Error![:0]const u8 {
    return try allocRenderPartialsZWithOptions(allocator, template, {}, data, .{});
}

/// Renders the `Template` with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderZWithOptions(allocator: Allocator, template: Template, data: anytype, comptime options: RenderTemplateOptions) Allocator.Error![:0]const u8 {
    return try allocRenderPartialsZWithOptions(allocator, template, {}, data, options);
}

/// Renders the `Template` with the given `data` and returns an owned sentinel-terminated slice with the content.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
/// Caller must free the memory
pub fn allocRenderPartialsZ(allocator: Allocator, template: Template, partials: anytype, data: anytype) Allocator.Error![:0]const u8 {
    return try allocRenderPartialsZWithOptions(allocator, template, partials, data, .{});
}

/// Renders the `Template` with the given `data` and returns an owned sentinel-terminated slice with the content.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
/// Caller must free the memory
pub fn allocRenderPartialsZWithOptions(allocator: Allocator, template: Template, partials: anytype, data: anytype, comptime options: RenderTemplateOptions) Allocator.Error![:0]const u8 {
    const render_options = RenderOptions{ .Template = options };
    return try RenderHelpers.allocRender(allocator, template.elements, partials, data, render_options, '\x00');
}

/// Renders the `Template` with the given `data` to a buffer.
pub fn bufRender(buf: []u8, template: Template, data: anytype) (Allocator.Error || BufError)![]const u8 {
    return try bufRenderPartialsWithOptions(buf, template, {}, data, .{});
}

/// Renders the `Template` with the given `data` to a buffer.
pub fn bufRenderWithOptions(buf: []u8, template: Template, data: anytype, comptime options: RenderTemplateOptions) (Allocator.Error || BufError)![]const u8 {
    return try bufRenderPartialsWithOptions(buf, template, {}, data, options);
}

/// Renders the `Template` with the given `data` to a buffer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
pub fn bufRenderPartials(buf: []u8, template: Template, partials: anytype, data: anytype) (Allocator.Error || BufError)![]const u8 {
    return bufRenderPartialsWithOptions(buf, template, partials, data, .{});
}

/// Renders the `Template` with the given `data` to a buffer.
/// `partials` can be a tuple, an array, slice or a HashMap containing the partial's name as key and the `Template` as value
pub fn bufRenderPartialsWithOptions(buf: []u8, template: Template, partials: anytype, data: anytype, comptime options: RenderTemplateOptions) (Allocator.Error || BufError)![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    try renderPartialsWithOptions(template, partials, data, fbs.writer(), options);
    return fbs.getWritten();
}

/// Renders the `Template` with the given `data` to a buffer, terminated by the zero sentinel.
pub fn bufRenderZ(buf: []u8, template: Template, data: anytype) (Allocator.Error || BufError)![:0]const u8 {
    return try bufRenderPartialsZWithOptions(buf, template, {}, data, .{});
}

/// Renders the `Template` with the given `data` to a buffer, terminated by the zero sentinel.
pub fn bufRenderZWithOptions(buf: []u8, template: Template, data: anytype, comptime options: RenderTemplateOptions) (Allocator.Error || BufError)![:0]const u8 {
    return try bufRenderPartialsZWithOptions(buf, template, {}, data, options);
}

/// Renders the `Template` with the given `data` to a buffer, terminated by the zero sentinel.
pub fn bufRenderPartialsZ(buf: []u8, template: Template, partials: anytype, data: anytype) (Allocator.Error || BufError)![:0]const u8 {
    return try bufRenderPartialsZWithOptions(buf, template, partials, data, .{});
}

/// Renders the `Template` with the given `data` to a buffer, terminated by the zero sentinel.
pub fn bufRenderPartialsZWithOptions(buf: []u8, template: Template, partials: anytype, data: anytype, comptime options: RenderTemplateOptions) (Allocator.Error || BufError)![:0]const u8 {
    var ret = try bufRenderPartialsWithOptions(buf, template, partials, data, options);

    if (ret.len < buf.len) {
        buf[ret.len] = '\x00';
        return buf[0..ret.len :0];
    } else {
        return BufError.NoSpaceLeft;
    }
}

/// Parses the `template_text` and renders with the given `data` to a writer
pub fn renderText(allocator: Allocator, template_text: []const u8, data: anytype, writer: anytype) (Allocator.Error || ParseError || @TypeOf(writer).Error)!void {
    try renderTextPartialsWithOptions(allocator, template_text, {}, data, writer, .{});
}

/// Parses the `template_text` and renders with the given `data` to a writer
pub fn renderTextPartials(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype, writer: anytype) (Allocator.Error || ParseError || @TypeOf(writer).Error)!void {
    try renderTextPartialsWithOptions(allocator, template_text, partials, data, writer, .{});
}

/// Parses the `template_text` and renders with the given `data` to a writer
pub fn renderTextPartialsWithOptions(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype, writer: anytype, comptime options: RenderTextOptions) (Allocator.Error || ParseError || @TypeOf(writer).Error)!void {
    const render_options = RenderOptions{ .Text = options };
    try RenderHelpers.collect(allocator, template_text, partials, data, writer, render_options);
}

/// Parses the `template_text` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderText(allocator: Allocator, template_text: []const u8, data: anytype) (Allocator.Error || ParseError)![]const u8 {
    return try allocRenderTextPartialsWithOptions(allocator, template_text, {}, data, .{});
}

/// Parses the `template_text` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderTextPartials(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype) (Allocator.Error || ParseError)![]const u8 {
    return try allocRenderTextPartialsWithOptions(allocator, template_text, partials, data, .{});
}

/// Parses the `template_text` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderTextPartialsWithOptions(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype, comptime options: RenderTextOptions) (Allocator.Error || ParseError)![]const u8 {
    const render_options = RenderOptions{ .Text = options };
    return try RenderHelpers.allocCollect(allocator, template_text, partials, data, render_options, null);
}

/// Parses the `template_text` and renders with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderTextZ(allocator: Allocator, template_text: []const u8, data: anytype) (Allocator.Error || ParseError)![:0]const u8 {
    return try allocRenderTextZPartialsWithOptions(allocator, template_text, {}, data, .{});
}

/// Parses the `template_text` and renders with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderTextZPartials(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype) (Allocator.Error || ParseError)![:0]const u8 {
    return try allocRenderTextZPartialsWithOptions(allocator, template_text, partials, data, .{});
}

/// Parses the `template_text` and renders with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderTextZPartialsWithOptions(allocator: Allocator, template_text: []const u8, partials: anytype, data: anytype, comptime options: RenderTextOptions) (Allocator.Error || ParseError)![:0]const u8 {
    const render_options = RenderOptions{ .Text = options };
    return try RenderHelpers.allocCollect(allocator, template_text, partials, data, render_options, '\x00');
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` to a writer
pub fn renderFile(allocator: Allocator, template_absolute_path: []const u8, data: anytype, writer: anytype) (Allocator.Error || ParseError || FileError || @TypeOf(writer).Error)!void {
    try renderFilePartialsWithOptions(allocator, template_absolute_path, {}, data, writer, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` to a writer
pub fn renderFilePartials(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype, writer: anytype) (Allocator.Error || ParseError || FileError || @TypeOf(writer).Error)!void {
    try renderFilePartialsWithOptions(allocator, template_absolute_path, partials, data, writer, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` to a writer
pub fn renderFilePartialsWithOptions(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype, writer: anytype, comptime options: RenderFileOptions) (Allocator.Error || ParseError || FileError || @TypeOf(writer).Error)!void {
    const render_options = RenderOptions{ .File = options };
    try RenderHelpers.collect(allocator, template_absolute_path, partials, data, writer, render_options);
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderFile(allocator: Allocator, template_absolute_path: []const u8, data: anytype) (Allocator.Error || ParseError || FileError)![]const u8 {
    return try allocRenderFilePartialsWithOptions(allocator, template_absolute_path, {}, data, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderFilePartials(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype) (Allocator.Error || ParseError || FileError)![]const u8 {
    return try allocRenderFilePartialsWithOptions(allocator, template_absolute_path, partials, data, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderFilePartialsWithOptions(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype, comptime options: RenderFileOptions) (Allocator.Error || ParseError || FileError)![]const u8 {
    const render_options = RenderOptions{ .File = options };
    return try RenderHelpers.allocCollect(allocator, template_absolute_path, partials, data, render_options, null);
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderFileZ(allocator: Allocator, template_absolute_path: []const u8, data: anytype) (Allocator.Error || ParseError || FileError)![]const u8 {
    return try allocRenderFileZPartialsWithOptions(allocator, template_absolute_path, {}, data, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned slice with the content.
/// Caller must free the memory
pub fn allocRenderFileZPartials(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype) (Allocator.Error || ParseError || FileError)![]const u8 {
    return try allocRenderFileZPartialsWithOptions(allocator, template_absolute_path, partials, data, .{});
}

/// Parses the file indicated by `template_absolute_path` and renders with the given `data` and returns an owned sentinel-terminated slice with the content.
/// Caller must free the memory
pub fn allocRenderFileZPartialsWithOptions(allocator: Allocator, template_absolute_path: []const u8, partials: anytype, data: anytype, comptime options: RenderFileOptions) (Allocator.Error || ParseError || FileError)![:0]const u8 {
    const render_options = RenderOptions{ .File = options };
    return try RenderHelpers.allocCollect(allocator, template_absolute_path, partials, data, render_options, '\x00');
}

const RenderHelpers = struct {
    pub inline fn render(elements: []const Element, partials: anytype, data: anytype, writer: anytype, comptime options: RenderOptions) !void {
        const PartialsMap = map.PartialsMap(@TypeOf(partials), options);
        const Engine = RenderEngine(@TypeOf(writer), PartialsMap, options);

        try Engine.render(elements, data, writer, PartialsMap.init(partials));
    }

    pub inline fn allocRender(allocator: Allocator, elements: []const Element, partials: anytype, data: anytype, comptime options: RenderOptions, comptime sentinel: ?u8) !if (sentinel) |z| [:z]const u8 else []const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const Writer = @TypeOf(std.io.null_writer);
        const PartialsMap = map.PartialsMap(@TypeOf(partials), options);
        const Engine = RenderEngine(Writer, PartialsMap, options);

        try Engine.bufRender(&list, elements, data, PartialsMap.init(partials));

        return if (comptime sentinel) |z|
            list.toOwnedSliceSentinel(z)
        else
            list.toOwnedSlice();
    }

    pub inline fn collect(allocator: Allocator, template: []const u8, partials: anytype, data: anytype, writer: anytype, comptime options: RenderOptions) !void {
        const PartialsMap = map.PartialsMap(@TypeOf(partials), options);
        const Engine = RenderEngine(@TypeOf(writer), PartialsMap, options);

        try Engine.collect(allocator, template, data, writer, PartialsMap.init(allocator, partials));
    }

    pub inline fn allocCollect(allocator: Allocator, template: []const u8, partials: anytype, data: anytype, comptime options: RenderOptions, comptime sentinel: ?u8) !if (sentinel) |z| [:z]const u8 else []const u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const Writer = @TypeOf(std.io.null_writer);
        const PartialsMap = map.PartialsMap(@TypeOf(partials), options);
        const Engine = RenderEngine(Writer, PartialsMap, options);

        try Engine.bufCollect(allocator, &list, template, data, PartialsMap.init(allocator, partials));

        return if (comptime sentinel) |z|
            list.toOwnedSliceSentinel(z)
        else
            list.toOwnedSlice();
    }
};

///
/// Group functions and structs that are denpendent of Writer and RenderOptions
pub fn RenderEngine(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const has_indentation = !PartialsMap.isEmpty() and options.preseveLineBreaksAndIndentation();

    return struct {
        pub const Context = context.Context(Writer, PartialsMap, options);
        pub const ContextStack = Context.ContextStack;
        pub const OutWriter = Context.OutWriter;
        pub const PartialsMap = PartialsMap;

        pub const Indentation = if (has_indentation) indent.Indentation else indent.Indentation.Null;
        pub const IndentationQueue = if (has_indentation) indent.IndentationQueue else indent.IndentationQueue.Null;

        pub const Invoker = invoker.Invoker(Writer, PartialsMap, options);

        pub fn render(elements: []const Element, data: anytype, writer: Writer, partials_map: PartialsMap) !void {
            const Data = @TypeOf(data);
            const by_value = comptime Fields.byValue(Data);

            var indentation_queue = IndentationQueue{};
            var data_render = DataRender{
                .out_writer = .{ .Writer = writer },
                .stack = &ContextStack{
                    .parent = null,
                    .ctx = context.getContext(
                        Writer,
                        if (by_value) data else @as(*const Data, &data),
                        PartialsMap,
                        options,
                    ),
                },
                .indentation_queue = &indentation_queue,
            };

            try data_render.render(
                elements,
                partials_map,
            );
        }

        pub fn bufRender(list: *std.ArrayList(u8), elements: []const Element, data: anytype, partials_map: PartialsMap) !void {
            const Data = @TypeOf(data);
            const by_value = comptime Fields.byValue(Data);

            var indentation_queue = IndentationQueue{};
            var data_render = DataRender{
                .out_writer = .{ .Buffer = list },
                .stack = &ContextStack{
                    .parent = null,
                    .ctx = context.getContext(
                        Writer,
                        if (by_value) data else @as(*const Data, &data),
                        PartialsMap,
                        options,
                    ),
                },
                .indentation_queue = &indentation_queue,
            };

            try data_render.render(
                elements,
                partials_map,
            );
        }

        pub fn collect(allocator: Allocator, template: []const u8, data: anytype, writer: Writer, partials_map: PartialsMap) !void {
            const Data = @TypeOf(data);
            const by_value = comptime Fields.byValue(Data);

            var indentation_queue = IndentationQueue{};
            var data_render = DataRender{
                .out_writer = .{ .Writer = writer },
                .stack = &ContextStack{
                    .parent = null,
                    .ctx = context.getContext(
                        Writer,
                        if (by_value) data else @as(*const Data, &data),
                        PartialsMap,
                        options,
                    ),
                },
                .indentation_queue = &indentation_queue,
            };

            try data_render.collect(
                allocator,
                template,
                partials_map,
            );
        }

        pub fn bufCollect(allocator: Allocator, list: *std.ArrayList(u8), template: []const u8, data: anytype, partials_map: PartialsMap) !void {
            const Data = @TypeOf(data);
            const by_value = comptime Fields.byValue(Data);

            var indentation_queue = IndentationQueue{};
            var data_render = DataRender{
                .out_writer = .{ .Buffer = list },
                .stack = &ContextStack{
                    .parent = null,
                    .ctx = context.getContext(
                        Writer,
                        if (by_value) data else @as(*const Data, &data),
                        PartialsMap,
                        options,
                    ),
                },
                .indentation_queue = &indentation_queue,
            };

            try data_render.collect(
                allocator,
                template,
                partials_map,
            );
        }

        const DataRender = struct {
            const Self = @This();
            pub const Error = Allocator.Error || Writer.Error;

            out_writer: OutWriter,
            stack: *const ContextStack,
            indentation_queue: *IndentationQueue,

            pub fn render(self: *Self, elements: []const Element, partials: PartialsMap) !void {
                try renderLevel(self.out_writer, self.stack, self.indentation_queue, elements, partials);
            }

            pub fn collect(self: *Self, allocator: Allocator, template: []const u8, partials: PartialsMap) !void {
                switch (comptime options) {
                    .Text => |text_options| {
                        const template_options = TemplateOptions{
                            .source = .{ .String = .{ .copy_strings = false } },
                            .output = .Render,
                            .features = text_options.features,
                        };

                        var template_loader = TemplateLoader(template_options){
                            .allocator = allocator,
                        };
                        errdefer template_loader.deinit();
                        try template_loader.collectElements(template, partials, self);
                    },
                    .File => |file_options| {
                        const render_file_options = TemplateOptions{
                            .source = .{ .Stream = .{ .read_buffer_size = file_options.read_buffer_size } },
                            .output = .Render,
                            .features = file_options.features,
                        };

                        var template_loader = TemplateLoader(render_file_options){
                            .allocator = allocator,
                        };
                        errdefer template_loader.deinit();

                        try template_loader.collectElementsFromFile(template, partials, self);
                    },

                    .Template => unreachable,
                }
            }
        };

        pub fn renderLevel(
            out_writer: OutWriter,
            stack: *const ContextStack,
            indentation_queue: *IndentationQueue,
            children: ?[]const Element,
            partials_map: PartialsMap,
        ) (Allocator.Error || Writer.Error)!void {
            if (children) |elements| {
                for (elements) |*element| {
                    switch (element.*) {
                        .StaticText => |content| try writeAll(out_writer, content, indentation_queue.get(element)),
                        .Interpolation => |path| try interpolate(out_writer, stack, partials_map, path, .Escaped, indentation_queue.get(element)),
                        .UnescapedInterpolation => |path| try interpolate(out_writer, stack, partials_map, path, .Unescaped, indentation_queue.get(element)),
                        .Section => |section| {
                            if (getIterator(stack, section.key)) |*iterator| {
                                if (iterator.lambda()) |lambda_ctx| {

                                    //TODO: Add template options
                                    assert(section.inner_text != null);
                                    assert(section.delimiters != null);

                                    const expand_result = try lambda_ctx.expandLambda(out_writer, stack, partials_map, "", section.inner_text.?, .Unescaped, indentation_queue.get(element), section.delimiters.?);
                                    assert(expand_result == .Lambda);
                                } else while (iterator.next()) |item_ctx| {
                                    var next_level = ContextStack{
                                        .parent = stack,
                                        .ctx = item_ctx,
                                    };

                                    indentation_queue.indentSection(iterator.hasNext());
                                    defer indentation_queue.unindentSection();

                                    try renderLevel(out_writer, &next_level, indentation_queue, section.content, partials_map);
                                }
                            }
                        },
                        .InvertedSection => |section| {

                            // Lambdas aways evaluate as "true" for inverted section
                            // Broken paths, empty lists, null and false evaluates as "false"

                            const truthy = if (getIterator(stack, section.key)) |*iterator| iterator.truthy() else false;
                            if (!truthy) {
                                try renderLevel(out_writer, stack, indentation_queue, section.content, partials_map);
                            }
                        },

                        .Partial => |partial| {
                            if (comptime PartialsMap.isEmpty()) {
                                continue;
                            } else if (partials_map.get(partial.key)) |partial_template| {
                                if (if (comptime has_indentation) partial.indentation else null) |value| {
                                    var next_indentation_queue = indentation_queue.indent(&IndentationQueue.Node{ .indentation = value, .last_indented_element = undefined });
                                    defer next_indentation_queue.unindent();

                                    try writeAll(out_writer, value, .{});
                                    try renderLevelPartials(partial_template, out_writer, stack, &next_indentation_queue, partials_map);
                                } else {
                                    try renderLevelPartials(partial_template, out_writer, stack, indentation_queue, partials_map);
                                }
                            }
                        },

                        //TODO Parent, Block
                        else => {},
                    }
                }
            }
        }

        fn renderLevelPartials(partial_template: PartialsMap.Template, out_writer: OutWriter, stack: *const ContextStack, indentation_queue: *IndentationQueue, partials_map: PartialsMap) !void {
            comptime assert(!PartialsMap.isEmpty());
            var data_render = DataRender{
                .out_writer = out_writer,
                .stack = stack,
                .indentation_queue = indentation_queue,
            };

            switch (options) {
                .Template => {
                    try data_render.render(partial_template.elements, partials_map);
                },
                .Text, .File => {
                    data_render.collect(partials_map.allocator, partial_template, partials_map) catch unreachable;
                },
            }
        }

        fn interpolate(
            out_writer: OutWriter,
            stack: *const ContextStack,
            partials_map: PartialsMap,
            path: []const u8,
            escape: Escape,
            identation: Indentation,
        ) (Allocator.Error || Writer.Error)!void {
            var level: ?*const ContextStack = stack;

            while (level) |current| : (level = current.parent) {
                const path_resolution = try current.ctx.interpolate(out_writer, path, escape, identation);

                switch (path_resolution) {
                    .Field => {
                        // Success, break the loop
                        break;
                    },

                    .Lambda => {

                        // Expand the lambda against the current context and break the loop
                        const expand_result = try current.ctx.expandLambda(out_writer, stack, partials_map, path, "", escape, identation, .{});
                        assert(expand_result == .Lambda);
                        break;
                    },

                    .IteratorConsumed, .ChainBroken => {
                        // Not rendered, but should NOT try against the parent context
                        break;
                    },

                    .NotFoundInContext => {
                        // Not rendered, should try against the parent context
                        continue;
                    },
                }
            }
        }

        fn writeAll(out_writer: OutWriter, content: []const u8, indentation: Indentation) (Allocator.Error || Writer.Error)!void {
            switch (out_writer) {
                .Writer => |writer| _ = try unescapedWrite(writer, content, indentation),
                .Buffer => |list| _ = try unescapedWrite(list.writer(), content, indentation),
            }
        }

        fn writeIndentation(out_writer: OutWriter, indentation: Indentation) (Allocator.Error || Writer.Error)!void {
            switch (out_writer) {
                .Writer => |writer| _ = try indentation.write(writer),
                .Buffer => |list| _ = try indentation.write(list.writer()),
            }
        }

        fn getIterator(stack: *const ContextStack, path: []const u8) ?Context.Iterator {
            var level: ?*const ContextStack = stack;

            while (level) |current| : (level = current.parent) {
                switch (current.ctx.iterator(path)) {
                    .Field => |found| return found,

                    .Lambda => |found| return found,

                    .IteratorConsumed, .ChainBroken => {
                        // Not found, but should NOT try against the parent context
                        break;
                    },

                    .NotFoundInContext => {
                        // Should try against the parent context
                        continue;
                    },
                }
            }

            return null;
        }

        pub fn escapedWrite(
            writer: anytype,
            value: []const u8,
            escape: Escape,
            indentation: Indentation,
        ) @TypeOf(writer).Error!usize {

            // Avoid too many runtime comparations inside the loop, by epecializing versions of the same function at comptime

            return switch (escape) {
                .Escaped => try write(writer, .Escaped, indentation, value),
                .Unescaped => return try write(writer, .Unescaped, indentation, value),
            };
        }

        pub fn unescapedWrite(
            writer: anytype,
            value: []const u8,
            indentation: Indentation,
        ) @TypeOf(writer).Error!usize {

            // Avoid too many runtime comparations inside the loop, by epecializing versions of the same function at comptime
            return try write(writer, .Unescaped, indentation, value);
        }

        fn write(
            writer: anytype,
            comptime escape: Escape,
            indentation: Indentation,
            value: []const u8,
        ) @TypeOf(writer).Error!usize {
            const escaped = escape == .Escaped;
            const indented = @sizeOf(Indentation) > 0;

            if (comptime escaped or indented) {
                const @"null" = '\x00';
                const html_null: []const u8 = "\u{fffd}";

                var index: usize = 0;
                var written_bytes: usize = 0;
                var new_line: if (indented) bool else void = if (indented) false else {};

                var char_index: usize = 0;
                while (char_index < value.len) : (char_index += 1) {
                    const char = value[char_index];

                    if (comptime indented) {

                        // The indentation must be inserted after the line break
                        // Supports both \n and \r\n

                        if (new_line) {
                            defer new_line = false;

                            if (char_index > index) {
                                const slice = value[index..char_index];
                                try writer.writeAll(slice);
                                written_bytes += slice.len;
                            }

                            written_bytes += try indentation.write(.Middle, writer);

                            index = char_index;
                        } else if (char == '\n') {
                            new_line = true;
                            continue;
                        }
                    }

                    if (comptime escaped) {
                        const replace = switch (char) {
                            '"' => "&quot;",
                            '\'' => "&#39;",
                            '&' => "&amp;",
                            '<' => "&lt;",
                            '>' => "&gt;",
                            @"null" => html_null,
                            else => continue,
                        };

                        if (char_index > index) {
                            const slice = value[index..char_index];
                            try writer.writeAll(slice);
                            written_bytes += slice.len;
                        }

                        try writer.writeAll(replace);
                        written_bytes += replace.len;

                        index = char_index + 1;
                    }
                }

                if (index < value.len) {
                    const slice = value[index..];
                    try writer.writeAll(slice);
                    written_bytes += slice.len;
                }

                if (comptime indented) {
                    if (new_line) written_bytes += try indentation.write(.Last, writer);
                }

                return written_bytes;
            } else {
                try writer.writeAll(value);
                return value.len;
            }
        }
    };
}

test {
    _ = context;
    _ = map;

    _ = tests.spec;
    _ = tests.extra;
    _ = tests.api;
    _ = tests.escape_tests;
}

const tests = struct {
    const spec = struct {
        test {
            _ = interpolation;
            _ = sections;
            _ = inverted;
            _ = delimiters;
            _ = lambdas;
            _ = partials;
        }

        /// Those tests are a verbatim copy from
        /// https://github.com/mustache/spec/blob/master/specs/interpolation.yml  
        const interpolation = struct {

            // Mustache-free templates should render as-is.
            test "No Interpolation" {
                const template_text = "Hello from {Mustache}!";
                var data = .{};
                try expectRender(template_text, data, "Hello from {Mustache}!");
            }

            // Unadorned tags should interpolate content into the template.
            test "Basic Interpolation" {
                const template_text = "Hello, {{subject}}!";

                var data = .{
                    .subject = "world",
                };

                try expectRender(template_text, data, "Hello, world!");
            }

            // Basic interpolation should be HTML escaped.
            test "HTML Escaping" {
                const template_text = "These characters should be HTML escaped: {{forbidden}}";

                var data = .{
                    .forbidden = "& \" < >",
                };

                try expectRender(template_text, data, "These characters should be HTML escaped: &amp; &quot; &lt; &gt;");
            }

            // Triple mustaches should interpolate without HTML escaping.
            test "Triple Mustache" {
                const template_text = "These characters should not be HTML escaped: {{{forbidden}}}";

                var data = .{
                    .forbidden = "& \" < >",
                };

                try expectRender(template_text, data, "These characters should not be HTML escaped: & \" < >");
            }

            // Ampersand should interpolate without HTML escaping.
            test "Ampersand" {
                const template_text = "These characters should not be HTML escaped: {{&forbidden}}";

                var data = .{
                    .forbidden = "& \" < >",
                };

                try expectRender(template_text, data, "These characters should not be HTML escaped: & \" < >");
            }

            // Integers should interpolate seamlessly.
            test "Basic Integer Interpolation" {
                const template_text = "{{mph}} miles an hour!";

                var data = .{
                    .mph = 85,
                };

                try expectRender(template_text, data, "85 miles an hour!");
            }

            // Integers should interpolate seamlessly.
            test "Triple Mustache Integer Interpolation" {
                const template_text = "{{{mph}}} miles an hour!";

                var data = .{
                    .mph = 85,
                };

                try expectRender(template_text, data, "85 miles an hour!");
            }

            // Integers should interpolate seamlessly.
            test "Ampersand Integer Interpolation" {
                const template_text = "{{&mph}} miles an hour!";

                var data = .{
                    .mph = 85,
                };

                try expectRender(template_text, data, "85 miles an hour!");
            }

            // Decimals should interpolate seamlessly with proper significance.
            test "Basic Decimal Interpolation" {
                if (true) return error.SkipZigTest;

                const template_text = "{{power}} jiggawatts!";

                {
                    // f32

                    const Data = struct {
                        power: f32,
                    };

                    var data = Data{
                        .power = 1.210,
                    };

                    try expectRender(template_text, data, "1.21 jiggawatts!");
                }

                {
                    // f64

                    const Data = struct {
                        power: f64,
                    };

                    var data = Data{
                        .power = 1.210,
                    };

                    try expectRender(template_text, data, "1.21 jiggawatts!");
                }

                {
                    // Comptime float
                    var data = .{
                        .power = 1.210,
                    };

                    try expectRender(template_text, data, "1.21 jiggawatts!");
                }

                {
                    // Comptime negative float
                    var data = .{
                        .power = -1.210,
                    };

                    try expectRender(template_text, data, "-1.21 jiggawatts!");
                }
            }

            // Decimals should interpolate seamlessly with proper significance.
            test "Triple Mustache Decimal Interpolation" {
                const template_text = "{{{power}}} jiggawatts!";

                {
                    // Comptime float
                    var data = .{
                        .power = 1.210,
                    };

                    try expectRender(template_text, data, "1.21 jiggawatts!");
                }

                {
                    // Comptime negative float
                    var data = .{
                        .power = -1.210,
                    };

                    try expectRender(template_text, data, "-1.21 jiggawatts!");
                }
            }

            // Decimals should interpolate seamlessly with proper significance.
            test "Ampersand Decimal Interpolation" {
                const template_text = "{{&power}} jiggawatts!";

                {
                    // Comptime float
                    var data = .{
                        .power = 1.210,
                    };

                    try expectRender(template_text, data, "1.21 jiggawatts!");
                }
            }

            // Nulls should interpolate as the empty string.
            test "Basic Null Interpolation" {
                const template_text = "I ({{cannot}}) be seen!";

                {
                    // Optional null

                    const Data = struct {
                        cannot: ?[]const u8,
                    };

                    var data = Data{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }

                {
                    // Comptime null

                    var data = .{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }
            }

            // Nulls should interpolate as the empty string.
            test "Triple Mustache Null Interpolation" {
                const template_text = "I ({{{cannot}}}) be seen!";

                {
                    // Optional null

                    const Data = struct {
                        cannot: ?[]const u8,
                    };

                    var data = Data{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }

                {
                    // Comptime null

                    var data = .{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }
            }

            // Nulls should interpolate as the empty string.
            test "Ampersand Null Interpolation" {
                const template_text = "I ({{&cannot}}) be seen!";

                {
                    // Optional null

                    const Data = struct {
                        cannot: ?[]const u8,
                    };

                    var data = Data{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }

                {
                    // Comptime null

                    var data = .{
                        .cannot = null,
                    };

                    try expectRender(template_text, data, "I () be seen!");
                }
            }

            // Failed context lookups should default to empty strings.
            test "Basic Context Miss Interpolation" {
                const template_text = "I ({{cannot}}) be seen!";

                var data = .{};

                try expectRender(template_text, data, "I () be seen!");
            }

            // Failed context lookups should default to empty strings.
            test "Triple Mustache Context Miss Interpolation" {
                const template_text = "I ({{{cannot}}}) be seen!";

                var data = .{};

                try expectRender(template_text, data, "I () be seen!");
            }

            // Failed context lookups should default to empty strings
            test "Ampersand Context Miss Interpolation" {
                const template_text = "I ({{&cannot}}) be seen!";

                var data = .{};

                try expectRender(template_text, data, "I () be seen!");
            }

            // Dotted names should be considered a form of shorthand for sections.
            test "Dotted Names - Basic Interpolation" {
                const template_text = "'{{person.name}}' == '{{#person}}{{name}}{{/person}}'";

                var data = .{
                    .person = .{
                        .name = "Joe",
                    },
                };

                try expectRender(template_text, data, "'Joe' == 'Joe'");
            }

            // Dotted names should be considered a form of shorthand for sections.
            test "Dotted Names - Triple Mustache Interpolation" {
                const template_text = "'{{{person.name}}}' == '{{#person}}{{{name}}}{{/person}}'";

                var data = .{
                    .person = .{
                        .name = "Joe",
                    },
                };

                try expectRender(template_text, data, "'Joe' == 'Joe'");
            }

            // Dotted names should be considered a form of shorthand for sections.
            test "Dotted Names - Ampersand Interpolation" {
                const template_text = "'{{&person.name}}' == '{{#person}}{{&name}}{{/person}}'";

                var data = .{
                    .person = .{
                        .name = "Joe",
                    },
                };

                try expectRender(template_text, data, "'Joe' == 'Joe'");
            }

            // Dotted names should be functional to any level of nesting.
            test "Dotted Names - Arbitrary Depth" {
                const template_text = "'{{a.b.c.d.e.name}}' == 'Phil'";

                var data = .{
                    .a = .{ .b = .{ .c = .{ .d = .{ .e = .{ .name = "Phil" } } } } },
                };

                try expectRender(template_text, data, "'Phil' == 'Phil'");
            }

            // Any falsey value prior to the last part of the name should yield ''
            test "Dotted Names - Broken Chains" {
                const template_text = "'{{a.b.c}}' == ''";

                var data = .{
                    .a = .{},
                };

                try expectRender(template_text, data, "'' == ''");
            }

            // Each part of a dotted name should resolve only against its parent.
            test "Dotted Names - Broken Chain Resolution" {
                const template_text = "'{{a.b.c.name}}' == ''";

                var data = .{
                    .a = .{ .b = .{} },
                    .c = .{ .name = "Jim" },
                };

                try expectRender(template_text, data, "'' == ''");
            }

            // The first part of a dotted name should resolve as any other name.
            test "Dotted Names - Initial Resolution" {
                const template_text = "'{{#a}}{{b.c.d.e.name}}{{/a}}' == 'Phil'";

                var data = .{
                    .a = .{ .b = .{ .c = .{ .d = .{ .e = .{ .name = "Phil" } } } } },
                    .b = .{ .c = .{ .d = .{ .e = .{ .name = "Wrong" } } } },
                };

                try expectRender(template_text, data, "'Phil' == 'Phil'");
            }

            // Dotted names should be resolved against former resolutions.
            test "Dotted Names - Context Precedence" {
                const template_text = "{{#a}}{{b.c}}{{/a}}";

                var data = .{
                    .a = .{ .b = .{} },
                    .b = .{ .c = "ERROR" },
                };

                try expectRender(template_text, data, "");
            }

            // Unadorned tags should interpolate content into the template.
            test "Implicit Iterators - Basic Interpolation" {
                const template_text = "Hello, {{.}}!";

                var data = "world";

                try expectRender(template_text, data, "Hello, world!");
            }

            // Basic interpolation should be HTML escaped..
            test "Implicit Iterators - HTML Escaping" {
                const template_text = "These characters should be HTML escaped: {{.}}";

                var data = "& \" < >";

                try expectRender(template_text, data, "These characters should be HTML escaped: &amp; &quot; &lt; &gt;");
            }

            // Triple mustaches should interpolate without HTML escaping.
            test "Implicit Iterators - Triple Mustache" {
                const template_text = "These characters should not be HTML escaped: {{{.}}}";

                var data = "& \" < >";

                try expectRender(template_text, data, "These characters should not be HTML escaped: & \" < >");
            }

            // Ampersand should interpolate without HTML escaping.
            test "Implicit Iterators - Ampersand" {
                const template_text = "These characters should not be HTML escaped: {{&.}}";

                var data = "& \" < >";

                try expectRender(template_text, data, "These characters should not be HTML escaped: & \" < >");
            }

            // Integers should interpolate seamlessly.
            test "Implicit Iterators - Basic Integer Interpolation" {
                const template_text = "{{.}} miles an hour!";

                {
                    // runtime int
                    const data: i32 = 85;

                    try expectRender(template_text, data, "85 miles an hour!");
                }
            }

            // Interpolation should not alter surrounding whitespace.
            test "Interpolation - Surrounding Whitespace" {
                const template_text = "| {{string}} |";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "| --- |");
            }

            // Interpolation should not alter surrounding whitespace.
            test "Triple Mustache - Surrounding Whitespace" {
                const template_text = "| {{{string}}} |";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "| --- |");
            }

            // Interpolation should not alter surrounding whitespace.
            test "Ampersand - Surrounding Whitespace" {
                const template_text = "| {{&string}} |";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "| --- |");
            }

            // Standalone interpolation should not alter surrounding whitespace.
            test "Interpolation - Standalone" {
                const template_text = "  {{string}}\n";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "  ---\n");
            }

            // Standalone interpolation should not alter surrounding whitespace.
            test "Triple Mustache - Standalone" {
                const template_text = "  {{{string}}}\n";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "  ---\n");
            }

            // Standalone interpolation should not alter surrounding whitespace.
            test "Ampersand - Standalone" {
                const template_text = "  {{&string}}\n";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "  ---\n");
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Interpolation With Padding" {
                const template_text = "|{{ string }}|";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "|---|");
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Triple Mustache With Padding" {
                const template_text = "|{{{ string }}}|";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "|---|");
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Ampersand With Padding" {
                const template_text = "|{{& string }}|";

                const data = .{
                    .string = "---",
                };

                try expectRender(template_text, data, "|---|");
            }
        };

        /// Those tests are a verbatim copy from
        ///https://github.com/mustache/spec/blob/master/specs/sections.yml
        const sections = struct {

            // Truthy sections should have their contents rendered.
            test "Truthy" {
                const template_text = "{{#boolean}}This should be rendered.{{/boolean}}";
                const expected = "This should be rendered.";

                {
                    var data = .{ .boolean = true };

                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { boolean: bool };
                    var data = Data{ .boolean = true };

                    try expectRender(template_text, data, expected);
                }
            }

            // Falsey sections should have their contents omitted.
            test "Falsey" {
                const template_text = "{{#boolean}}This should not be rendered.{{/boolean}}";
                const expected = "";

                {
                    var data = .{ .boolean = false };

                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { boolean: bool };
                    var data = Data{ .boolean = false };

                    try expectRender(template_text, data, expected);
                }
            }

            // Null is falsey.
            test "Null is falsey" {
                const template_text = "{{#null}}This should not be rendered.{{/null}}";
                const expected = "";

                {
                    var data = .{ .@"null" = null };

                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { @"null": ?[]i32 };
                    var data = Data{ .@"null" = null };

                    try expectRender(template_text, data, expected);
                }
            }

            // Objects and hashes should be pushed onto the context stack.
            test "Context" {
                const template_text = "{{#context}}Hi {{name}}.{{/context}}";
                const expected = "Hi Joe.";

                {
                    var data = .{ .context = .{ .name = "Joe" } };
                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { context: struct { name: []const u8 } };
                    var data = Data{ .context = .{ .name = "Joe" } };

                    try expectRender(template_text, data, expected);
                }
            }

            // Names missing in the current context are looked up in the stack.
            test "Parent contexts" {
                const template_text = "{{#sec}}{{a}}, {{b}}, {{c.d}}{{/sec}}";
                const expected = "foo, bar, baz";

                {
                    var data = .{ .a = "foo", .b = "wrong", .sec = .{ .b = "bar" }, .c = .{ .d = "baz" } };
                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { a: []const u8, b: []const u8, sec: struct { b: []const u8 }, c: struct { d: []const u8 } };
                    var data = Data{ .a = "foo", .b = "wrong", .sec = .{ .b = "bar" }, .c = .{ .d = "baz" } };

                    try expectRender(template_text, data, expected);
                }
            }

            // Non-false sections have their value at the top of context,
            // accessible as {{.}} or through the parent context. This gives
            // a simple way to display content conditionally if a variable exists.
            test "Variable test" {
                const template_text = "{{#foo}}{{.}} is {{foo}}{{/foo}}";
                const expected = "bar is bar";

                {
                    var data = .{ .foo = "bar" };
                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct { foo: []const u8 };
                    var data = Data{ .foo = "bar" };

                    try expectRender(template_text, data, expected);
                }
            }

            // All elements on the context stack should be accessible within lists.
            test "List Contexts" {
                const template_text = "{{#tops}}{{#middles}}{{tname.lower}}{{mname}}.{{#bottoms}}{{tname.upper}}{{mname}}{{bname}}.{{/bottoms}}{{/middles}}{{/tops}}";
                const expected = "a1.A1x.A1y.";

                {
                    // TODO:
                    // All elements must be the same type in a tuple
                    // Rework the iterator to solve that limitation
                    const Bottom = struct {
                        bname: []const u8,
                    };

                    var data = .{
                        .tops = .{
                            .{
                                .tname = .{
                                    .upper = "A",
                                    .lower = "a",
                                },
                                .middles = .{
                                    .{
                                        .mname = "1",
                                        .bottoms = .{
                                            Bottom{ .bname = "x" },
                                            Bottom{ .bname = "y" },
                                        },
                                    },
                                },
                            },
                        },
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    const Bottom = struct {
                        bname: []const u8,
                    };

                    const Middle = struct {
                        mname: []const u8,
                        bottoms: []const Bottom,
                    };

                    const Top = struct {
                        tname: struct {
                            upper: []const u8,
                            lower: []const u8,
                        },
                        middles: []const Middle,
                    };

                    const Data = struct {
                        tops: []const Top,
                    };

                    var data = Data{
                        .tops = &.{
                            .{
                                .tname = .{
                                    .upper = "A",
                                    .lower = "a",
                                },
                                .middles = &.{
                                    .{
                                        .mname = "1",
                                        .bottoms = &.{
                                            .{ .bname = "x" },
                                            .{ .bname = "y" },
                                        },
                                    },
                                },
                            },
                        },
                    };

                    try expectRender(template_text, data, expected);
                }
            }

            // All elements on the context stack should be accessible.
            test "Deeply Nested Contexts" {
                const template_text =
                    \\{{#a}}
                    \\{{one}}
                    \\{{#b}}
                    \\{{one}}{{two}}{{one}}
                    \\{{#c}}
                    \\{{one}}{{two}}{{three}}{{two}}{{one}}
                    \\{{#d}}
                    \\{{one}}{{two}}{{three}}{{four}}{{three}}{{two}}{{one}}
                    \\{{#five}}
                    \\{{one}}{{two}}{{three}}{{four}}{{five}}{{four}}{{three}}{{two}}{{one}}
                    \\{{one}}{{two}}{{three}}{{four}}{{.}}6{{.}}{{four}}{{three}}{{two}}{{one}}
                    \\{{one}}{{two}}{{three}}{{four}}{{five}}{{four}}{{three}}{{two}}{{one}}
                    \\{{/five}}
                    \\{{one}}{{two}}{{three}}{{four}}{{three}}{{two}}{{one}}
                    \\{{/d}}
                    \\{{one}}{{two}}{{three}}{{two}}{{one}}
                    \\{{/c}}
                    \\{{one}}{{two}}{{one}}
                    \\{{/b}}
                    \\{{one}}
                    \\{{/a}}
                ;

                const expected =
                    \\1
                    \\121
                    \\12321
                    \\1234321
                    \\123454321
                    \\12345654321
                    \\123454321
                    \\1234321
                    \\12321
                    \\121
                    \\1
                    \\
                ;

                {
                    var data = .{
                        .a = .{ .one = 1 },
                        .b = .{ .two = 2 },
                        .c = .{ .three = 3, .d = .{ .four = 4, .five = 5 } },
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    const Data = struct {
                        a: struct { one: u32 },
                        b: struct { two: i32 },
                        c: struct { three: usize, d: struct { four: u8, five: i16 } },
                    };

                    var data = Data{
                        .a = .{ .one = 1 },
                        .b = .{ .two = 2 },
                        .c = .{ .three = 3, .d = .{ .four = 4, .five = 5 } },
                    };

                    try expectRender(template_text, data, expected);
                }
            }

            // Lists should be iterated; list items should visit the context stack.
            test "List" {
                const template_text = "{{#list}}{{item}}{{/list}}";
                const expected = "123";

                {
                    // slice
                    const Data = struct { list: []const struct { item: u32 } };

                    var data = Data{
                        .list = &.{
                            .{ .item = 1 },
                            .{ .item = 2 },
                            .{ .item = 3 },
                        },
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [3]struct { item: u32 } };

                    var data = Data{
                        .list = .{
                            .{ .item = 1 },
                            .{ .item = 2 },
                            .{ .item = 3 },
                        },
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{
                        .list = .{
                            .{ .item = 1 },
                            .{ .item = 2 },
                            .{ .item = 3 },
                        },
                    };

                    try expectRender(template_text, data, expected);
                }
            }

            // Empty lists should behave like falsey values.
            test "Empty List" {
                const template_text = "{{#list}}Yay lists!{{/list}}";
                const expected = "";

                {
                    // slice
                    const Data = struct { list: []const struct { item: u32 } };

                    var data = Data{
                        .list = &.{},
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [0]struct { item: u32 } };

                    var data = Data{
                        .list = .{},
                    };

                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{
                        .list = .{},
                    };

                    try expectRender(template_text, data, expected);
                }
            }

            // Multiple sections per template should be permitted.
            test "Doubled" {
                const template_text =
                    \\{{#bool}}
                    \\* first
                    \\{{/bool}}
                    \\* {{two}}
                    \\{{#bool}}
                    \\* third
                    \\{{/bool}}
                ;
                const expected =
                    \\* first
                    \\* second
                    \\* third
                    \\
                ;

                var data = .{ .bool = true, .two = "second" };
                try expectRender(template_text, data, expected);
            }

            // Nested truthy sections should have their contents rendered.
            test "Nested (Truthy)" {
                const template_text = "| A {{#bool}}B {{#bool}}C{{/bool}} D{{/bool}} E |";
                const expected = "| A B C D E |";

                var data = .{ .bool = true };
                try expectRender(template_text, data, expected);
            }

            // Nested falsey sections should be omitted.
            test "Nested (Falsey)" {
                const template_text = "| A {{#bool}}B {{#bool}}C{{/bool}} D{{/bool}} E |";
                const expected = "| A  E |";

                var data = .{ .bool = false };
                try expectRender(template_text, data, expected);
            }

            // Failed context lookups should be considered falsey.
            test "Context Misses" {
                const template_text = "[{{#missing}}Found key 'missing'!{{/missing}}]";
                const expected = "[]";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Implicit iterators should directly interpolate strings.
            test "Implicit Iterator - String" {
                const template_text = "{{#list}}({{.}}){{/list}}";
                const expected = "(a)(b)(c)(d)(e)";

                {
                    // slice
                    const Data = struct { list: []const []const u8 };
                    var data = Data{ .list = &.{ "a", "b", "c", "d", "e" } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [5][]const u8 };
                    var data = Data{ .list = .{ "a", "b", "c", "d", "e" } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{ "a", "b", "c", "d", "e" } };
                    try expectRender(template_text, data, expected);
                }
            }

            // Implicit iterators should cast integers to strings and interpolate.
            test "Implicit Iterator - Integer" {
                const template_text = "{{#list}}({{.}}){{/list}}";
                const expected = "(1)(2)(3)(4)(5)";

                {
                    // slice
                    const Data = struct { list: []const u32 };
                    var data = Data{ .list = &.{ 1, 2, 3, 4, 5 } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [5]u32 };
                    var data = Data{ .list = .{ 1, 2, 3, 4, 5 } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{ 1, 2, 3, 4, 5 } };
                    try expectRender(template_text, data, expected);
                }
            }

            // Implicit iterators should cast decimals to strings and interpolate.
            test "Implicit Iterator - Decimal" {
                if (true) return error.SkipZigTest;

                const template_text = "{{#list}}({{.}}){{/list}}";
                const expected = "(1.1)(2.2)(3.3)(4.4)(5.5)";

                {
                    // slice
                    const Data = struct { list: []const f32 };
                    var data = Data{ .list = &.{ 1.1, 2.2, 3.3, 4.4, 5.5 } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [5]f32 };
                    var data = Data{ .list = .{ 1.1, 2.2, 3.3, 4.4, 5.5 } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{ 1.1, 2.2, 3.3, 4.4, 5.5 } };
                    try expectRender(template_text, data, expected);
                }
            }

            // Implicit iterators should allow iterating over nested arrays.
            test "Implicit Iterator - Array" {
                const template_text = "{{#list}}({{#.}}{{.}}{{/.}}){{/list}}";
                const expected = "(123)(456)";

                {
                    // slice

                    const Data = struct { list: []const []const u32 };
                    var data = Data{ .list = &.{
                        &.{ 1, 2, 3 },
                        &.{ 4, 5, 6 },
                    } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // array
                    const Data = struct { list: [2][3]u32 };
                    var data = Data{ .list = .{
                        .{ 1, 2, 3 },
                        .{ 4, 5, 6 },
                    } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{
                        .{ 1, 2, 3 },
                        .{ 4, 5, 6 },
                    } };
                    try expectRender(template_text, data, expected);
                }
            }

            // Implicit iterators should allow iterating over nested arrays.
            test "Implicit Iterator - Mixed Array" {
                const template_text = "{{#list}}({{#.}}{{.}}{{/.}}){{/list}}";
                const expected = "(123)(abc)";

                // Tuple is the only way to have mixed element types inside a list
                var data = .{ .list = .{
                    .{ 1, 2, 3 },
                    .{ "a", "b", "c" },
                } };
                try expectRender(template_text, data, expected);
            }

            // Dotted names should be valid for Section tags.
            test "Dotted Names - Truthy" {
                const template_text = "'{{#a.b.c}}Here{{/a.b.c}}' == 'Here'";
                const expected = "'Here' == 'Here'";

                var data = .{ .a = .{ .b = .{ .c = true } } };
                try expectRender(template_text, data, expected);
            }

            // Dotted names should be valid for Section tags.
            test "Dotted Names - Falsey" {
                const template_text = "'{{#a.b.c}}Here{{/a.b.c}}' == ''";
                const expected = "'' == ''";

                var data = .{ .a = .{ .b = .{ .c = false } } };
                try expectRender(template_text, data, expected);
            }

            // Dotted names that cannot be resolved should be considered falsey.
            test "Dotted Names - Broken Chains" {
                const template_text = "'{{#a.b.c}}Here{{/a.b.c}}' == ''";
                const expected = "'' == ''";

                var data = .{ .a = .{} };
                try expectRender(template_text, data, expected);
            }

            // Sections should not alter surrounding whitespace.
            test "Surrounding Whitespace" {
                const template_text = " | {{#boolean}}\t|\t{{/boolean}} | \n";
                const expected = " | \t|\t | \n";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Sections should not alter internal whitespace.
            test "Internal Whitespace" {
                const template_text = " | {{#boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";
                const expected = " |  \n  | \n";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Single-line sections should not alter surrounding whitespace.
            test "Indented Inline Sections" {
                const template_text = " {{#boolean}}YES{{/boolean}}\n {{#boolean}}GOOD{{/boolean}}\n";
                const expected = " YES\n GOOD\n";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Standalone lines should be removed from the template.
            test "Standalone Lines" {
                const template_text =
                    \\| This Is
                    \\{{#boolean}}
                    \\|
                    \\{{/boolean}}
                    \\| A Line
                ;
                const expected =
                    \\| This Is
                    \\|
                    \\| A Line
                ;

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Indented standalone lines should be removed from the template.
            test "Indented Standalone Lines" {
                const template_text =
                    \\| This Is
                    \\  {{#boolean}}
                    \\|
                    \\  {{/boolean}}
                    \\| A Line
                ;
                const expected =
                    \\| This Is
                    \\|
                    \\| A Line
                ;

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // "\r\n" should be considered a newline for standalone tags.
            test "Standalone Line Endings" {
                const template_text = "|\r\n{{#boolean}}\r\n{{/boolean}}\r\n|";
                const expected = "|\r\n|";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to precede them.
            test "Standalone Line Endings" {
                const template_text = "  {{#boolean}}\n#{{/boolean}}\n/";
                const expected = "#\n/";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to follow them.
            test "Standalone Without Newline" {
                const template_text = "#{{#boolean}}\n/\n  {{/boolean}}";
                const expected = "#\n/\n";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Padding" {
                const template_text = "|{{# boolean }}={{/ boolean }}|";
                const expected = "|=|";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }
        };

        /// Those tests are a verbatim copy from
        /// https://github.com/mustache/spec/blob/master/specs/inverted.yml
        const inverted = struct {

            // Falsey sections should have their contents rendered.
            test "Falsey" {
                const template_text = "{{^boolean}}This should be rendered.{{/boolean}}";
                const expected = "This should be rendered.";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Truthy sections should have their contents omitted.
            test "Truthy" {
                const template_text = "{{^boolean}}This should not be rendered.{{/boolean}}";
                const expected = "";

                var data = .{ .boolean = true };
                try expectRender(template_text, data, expected);
            }

            // Null is falsey.
            test "Null is falsey" {
                const template_text = "{{^null}}This should be rendered.{{/null}}";
                const expected = "This should be rendered.";

                {
                    // comptime
                    var data = .{ .@"null" = null };
                    try expectRender(template_text, data, expected);
                }

                {
                    // runtime
                    const Data = struct { @"null": ?u0 };
                    var data = Data{ .@"null" = null };
                    try expectRender(template_text, data, expected);
                }
            }

            // Objects and hashes should behave like truthy values.
            test "Context" {
                const template_text = "{{^context}}Hi {{name}}.{{/context}}";
                const expected = "";

                var data = .{ .context = .{ .name = "Joe" } };
                try expectRender(template_text, data, expected);
            }

            // Lists should behave like truthy values.
            test "List" {
                const template_text = "{{^list}}{{n}}{{/list}}";
                const expected = "";

                {
                    // Slice
                    const Data = struct { list: []const struct { n: u32 } };
                    var data = Data{ .list = &.{ .{ .n = 1 }, .{ .n = 2 }, .{ .n = 3 } } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // Array
                    const Data = struct { list: [3]struct { n: u32 } };
                    var data = Data{ .list = .{ .{ .n = 1 }, .{ .n = 2 }, .{ .n = 3 } } };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{ .{ .n = 1 }, .{ .n = 2 }, .{ .n = 3 } } };
                    try expectRender(template_text, data, expected);
                }
            }

            // Empty lists should behave like falsey values.
            test "Empty List" {
                const template_text = "{{^list}}Yay lists!{{/list}}";
                const expected = "Yay lists!";

                {
                    // Slice
                    const Data = struct { list: []const struct { n: u32 } };
                    var data = Data{ .list = &.{} };
                    try expectRender(template_text, data, expected);
                }

                {
                    // Array
                    const Data = struct { list: [0]struct { n: u32 } };
                    var data = Data{ .list = .{} };
                    try expectRender(template_text, data, expected);
                }

                {
                    // tuple
                    var data = .{ .list = .{} };
                    try expectRender(template_text, data, expected);
                }
            }

            // Multiple sections per template should be permitted.
            test "Doubled" {
                const template_text =
                    \\{{^bool}}
                    \\* first
                    \\{{/bool}}
                    \\* {{two}}
                    \\{{^bool}}
                    \\* third
                    \\{{/bool}}
                ;
                const expected =
                    \\* first
                    \\* second
                    \\* third
                    \\
                ;

                var data = .{ .bool = false, .two = "second" };
                try expectRender(template_text, data, expected);
            }

            // Nested falsey sections should have their contents rendered.
            test "Nested (Falsey)" {
                const template_text = "| A {{^bool}}B {{^bool}}C{{/bool}} D{{/bool}} E |";
                const expected = "| A B C D E |";

                var data = .{ .bool = false };
                try expectRender(template_text, data, expected);
            }

            // Nested truthy sections should be omitted.
            test "Nested (Truthy)" {
                const template_text = "| A {{^bool}}B {{^bool}}C{{/bool}} D{{/bool}} E |";
                const expected = "| A  E |";

                var data = .{ .bool = true };
                try expectRender(template_text, data, expected);
            }

            // Failed context lookups should be considered falsey.
            test "Context Misses" {
                const template_text = "[{{^missing}}Cannot find key 'missing'!{{/missing}}]";
                const expected = "[Cannot find key 'missing'!]";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Dotted names should be valid for Inverted Section tags.
            test "Dotted Names - Truthy" {
                const template_text = "'{{^a.b.c}}Not Here{{/a.b.c}}' == ''";
                const expected = "'' == ''";

                var data = .{ .a = .{ .b = .{ .c = true } } };
                try expectRender(template_text, data, expected);
            }

            // Dotted names should be valid for Inverted Section tags.
            test "Dotted Names - Falsey" {
                const template_text = "'{{^a.b.c}}Not Here{{/a.b.c}}' == 'Not Here'";
                const expected = "'Not Here' == 'Not Here'";

                var data = .{ .a = .{ .b = .{ .c = false } } };
                try expectRender(template_text, data, expected);
            }

            // Dotted names that cannot be resolved should be considered falsey.
            test "Dotted Names - Broken Chains" {
                const template_text = "'{{^a.b.c}}Not Here{{/a.b.c}}' == 'Not Here'";
                const expected = "'Not Here' == 'Not Here'";

                var data = .{ .a = .{} };
                try expectRender(template_text, data, expected);
            }

            // Inverted sections should not alter surrounding whitespace.
            test "Surrounding Whitespace" {
                const template_text = " | {{^boolean}}\t|\t{{/boolean}} | \n";
                const expected = " | \t|\t | \n";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Inverted should not alter internal whitespace.
            test "Internal Whitespace" {
                const template_text = " | {{^boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";
                const expected = " |  \n  | \n";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Single-line sections should not alter surrounding whitespace.
            test "Indented Inline Sections" {
                const template_text = " {{^boolean}}NO{{/boolean}}\n {{^boolean}}WAY{{/boolean}}\n";
                const expected = " NO\n WAY\n";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Standalone lines should be removed from the template.
            test "Standalone Lines" {
                const template_text =
                    \\| This Is
                    \\{{^boolean}}
                    \\|
                    \\{{/boolean}}
                    \\| A Line
                ;
                const expected =
                    \\| This Is
                    \\|
                    \\| A Line
                ;

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Standalone indented lines should be removed from the template.
            test "Standalone Indented Lines" {
                const template_text =
                    \\| This Is
                    \\  {{^boolean}}
                    \\|
                    \\  {{/boolean}}
                    \\| A Line
                ;
                const expected =
                    \\| This Is
                    \\|
                    \\| A Line
                ;

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // "\r\n" should be considered a newline for standalone tags.
            test "Standalone Line Endings" {
                const template_text = "|\r\n{{^boolean}}\r\n{{/boolean}}\r\n|";
                const expected = "|\r\n|";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to precede them.
            test "Standalone Without Previous Line" {
                const template_text = "  {{^boolean}}\n^{{/boolean}}\n/";
                const expected = "^\n/";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to follow them.
            test "Standalone Without Newline" {
                const template_text = "^{{^boolean}}\n/\n  {{/boolean}}";
                const expected = "^\n/\n";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Padding" {
                const template_text = "|{{^ boolean }}={{/ boolean }}|";
                const expected = "|=|";

                var data = .{ .boolean = false };
                try expectRender(template_text, data, expected);
            }
        };

        /// Those tests are a verbatim copy from
        /// https://github.com/mustache/spec/blob/master/specs/delimiters.yml
        const delimiters = struct {

            // The equals sign (used on both sides) should permit delimiter changes.
            test "Pair Behavior" {
                const template_text = "{{=<% %>=}}(<%text%>)";
                const expected = "(Hey!)";

                var data = .{ .text = "Hey!" };
                try expectRender(template_text, data, expected);
            }

            // Characters with special meaning regexen should be valid delimiters.
            test "Special Characters" {
                const template_text = "({{=[ ]=}}[text])";
                const expected = "(It worked!)";

                var data = .{ .text = "It worked!" };
                try expectRender(template_text, data, expected);
            }

            // Delimiters set outside sections should persist.
            test "Sections" {
                const template_text =
                    \\[
                    \\{{#section}}
                    \\  {{data}}
                    \\  |data|
                    \\{{/section}}
                    \\{{= | | =}}
                    \\|#section|
                    \\  {{data}}
                    \\  |data|
                    \\|/section|
                    \\]
                ;

                const expected =
                    \\[
                    \\  I got interpolated.
                    \\  |data|
                    \\  {{data}}
                    \\  I got interpolated.
                    \\]
                ;

                var data = .{ .section = true, .data = "I got interpolated." };
                try expectRender(template_text, data, expected);
            }

            // Delimiters set outside inverted sections should persist.
            test "Inverted Sections" {
                const template_text =
                    \\[
                    \\{{^section}}
                    \\  {{data}}
                    \\  |data|
                    \\{{/section}}
                    \\{{= | | =}}
                    \\|^section|
                    \\  {{data}}
                    \\  |data|
                    \\|/section|
                    \\]
                ;

                const expected =
                    \\[
                    \\  I got interpolated.
                    \\  |data|
                    \\  {{data}}
                    \\  I got interpolated.
                    \\]
                ;

                var data = .{ .section = false, .data = "I got interpolated." };
                try expectRender(template_text, data, expected);
            }

            // Delimiters set in a parent template should not affect a partial.
            test "Partial Inheritence" {
                const template_text =
                    \\[ {{>include}} ]
                    \\{{= | | =}}
                    \\[ |>include| ]
                ;

                const partials_text = .{
                    .{
                        "include",
                        ".{{value}}.",
                    },
                };

                const expected =
                    \\[ .yes. ]
                    \\[ .yes. ]
                ;

                var data = .{ .value = "yes" };
                try expectRenderPartials(template_text, partials_text, data, expected);
            }

            // Delimiters set in a partial should not affect the parent template.
            test "Post-Partial Behavior" {
                const template_text =
                    \\[ {{>include}} ]
                    \\[ .{{value}}.  .|value|. ]
                ;

                const partials_text = .{
                    .{
                        "include",
                        ".{{value}}. {{= | | =}} .|value|.",
                    },
                };

                const expected =
                    \\[ .yes.  .yes. ]
                    \\[ .yes.  .|value|. ]
                ;

                var data = .{ .value = "yes" };
                try expectRenderPartials(template_text, partials_text, data, expected);
            }

            // Surrounding whitespace should be left untouched.
            test "Surrounding Whitespace" {
                const template_text = "| {{=@ @=}} |";
                const expected = "|  |";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Whitespace should be left untouched.
            test "Outlying Whitespace (Inline)" {
                const template_text = " | {{=@ @=}}\n";
                const expected = " | \n";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Indented standalone lines should be removed from the template.
            test "Indented Standalone Tag" {
                const template_text =
                    \\Begin.
                    \\  {{=@ @=}}
                    \\End.
                ;

                const expected =
                    \\Begin.
                    \\End.
                ;

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // "\r\n" should be considered a newline for standalone tags.
            test "Standalone Line Endings" {
                const template_text = "|\r\n{{= @ @ =}}\r\n|";
                const expected = "|\r\n|";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to precede them.
            test "Standalone Without Previous Line" {
                const template_text = "  {{=@ @=}}\n=";
                const expected = "=";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Standalone tags should not require a newline to follow them.
            test "Standalone Without Newline" {
                const template_text = "=\n  {{=@ @=}}";
                const expected = "=\n";

                var data = .{};
                try expectRender(template_text, data, expected);
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Pair with Padding" {
                const template_text = "|{{= @   @ =}}|";
                const expected = "||";

                var data = .{};
                try expectRender(template_text, data, expected);
            }
        };

        /// Those tests are a verbatim copy from
        /// https://github.com/mustache/spec/blob/master/specs/~lambdas.yml
        const lambdas = struct {

            // A lambda's return value should be interpolated.
            test "Interpolation" {
                const Data = struct {
                    text: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.write("world");
                    }
                };

                const template_text = "Hello, {{lambda}}!";
                const expected = "Hello, world!";

                var data = Data{ .text = "Hey!" };
                try expectRender(template_text, data, expected);
            }

            // A lambda's return value should be parsed.
            test "Interpolation - Expansion" {
                const Data = struct {
                    planet: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.render(testing.allocator, "{{planet}}");
                    }
                };

                const template_text = "Hello, {{lambda}}!";
                const expected = "Hello, world!";

                var data = Data{ .planet = "world" };
                try expectRender(template_text, data, expected);
            }

            // A lambda's return value should parse with the default delimiters.
            test "Interpolation - Alternate Delimiters" {
                const Data = struct {
                    planet: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.render(testing.allocator, "|planet| => {{planet}}");
                    }
                };

                const template_text = "{{= | | =}}\nHello, (|&lambda|)!";
                const expected = "Hello, (|planet| => world)!";

                var data = Data{ .planet = "world" };
                try expectRender(template_text, data, expected);
            }

            // Interpolated lambdas should not be cached.
            test "Interpolation - Multiple Calls" {
                const Data = struct {
                    calls: u32 = 0,

                    pub fn lambda(self: *@This(), ctx: mustache.LambdaContext) !void {
                        self.calls += 1;
                        try ctx.writeFormat("{}", .{self.calls});
                    }
                };

                const template_text = "{{lambda}} == {{{lambda}}} == {{lambda}}";
                const expected = "1 == 2 == 3";

                var data1 = Data{};
                try expectCachedRender(template_text, &data1, expected);

                var data2 = Data{};
                try expectStreamedRender(template_text, &data2, expected);
            }

            // Lambda results should be appropriately escaped.
            test "Escaping" {
                const Data = struct {
                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.write(">");
                    }
                };

                const template_text = "<{{lambda}}{{{lambda}}}";
                const expected = "<&gt;>";

                var data = Data{};
                try expectRender(template_text, data, expected);
            }

            // Lambdas used for sections should receive the raw section string.
            test "Section" {
                const Data = struct {
                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        if (std.mem.eql(u8, "{{x}}", ctx.inner_text)) {
                            try ctx.write("yes");
                        } else {
                            try ctx.write("no");
                        }
                    }
                };

                const template_text = "<{{#lambda}}{{x}}{{/lambda}}>";
                const expected = "<yes>";

                var data = Data{};
                try expectRender(template_text, data, expected);
            }

            // Lambdas used for sections should have their results parsed.
            test "Section - Expansion" {
                const Data = struct {
                    planet: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.renderFormat(testing.allocator, "{s}{s}{s}", .{ ctx.inner_text, "{{planet}}", ctx.inner_text });
                    }
                };

                const template_text = "<{{#lambda}}-{{/lambda}}>";
                const expected = "<-Earth->";

                var data = Data{ .planet = "Earth" };
                try expectRender(template_text, data, expected);
            }

            // Lambdas used for sections should parse with the current delimiters.
            test "Section - Alternate Delimiters" {
                const Data = struct {
                    planet: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.renderFormat(testing.allocator, "{s}{s}{s}", .{ ctx.inner_text, "{{planet}} => |planet|", ctx.inner_text });
                    }
                };

                const template_text = "{{= | | =}}<|#lambda|-|/lambda|>";
                const expected = "<-{{planet}} => Earth->";

                var data1 = Data{ .planet = "Earth" };
                try expectRender(template_text, &data1, expected);
            }

            // Lambdas used for sections should not be cached.
            test "Section - Multiple Calls" {
                const Data = struct {
                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        try ctx.renderFormat(testing.allocator, "__{s}__", .{ctx.inner_text});
                    }
                };

                const template_text = "{{#lambda}}FILE{{/lambda}} != {{#lambda}}LINE{{/lambda}}";
                const expected = "__FILE__ != __LINE__";

                var data = Data{};
                try expectRender(template_text, data, expected);
            }

            // Lambdas used for inverted sections should be considered truthy.
            test "Inverted Section" {
                const Data = struct {
                    static: []const u8,

                    pub fn lambda(ctx: mustache.LambdaContext) !void {
                        _ = ctx;
                    }
                };

                const template_text = "<{{^lambda}}{{static}}{{/lambda}}>";
                const expected = "<>";

                var data = Data{ .static = "static" };
                try expectRender(template_text, data, expected);
            }
        };

        /// Those tests are a verbatim copy from
        /// https://github.com/mustache/spec/blob/master/specs/partials.yml
        const partials = struct {

            // The greater-than operator should expand to the named partial.
            test "Basic Behavior" {
                const template_text = "'{{>text}}'";
                const partials_template_text = .{
                    .{ "text", "from partial" },
                };

                const expected = "'from partial'";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // The greater-than operator should expand to the named partial.
            test "Failed Lookup" {
                const template_text = "'{{>text}}'";
                const partials_template_text = .{};

                const expected = "''";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // The greater-than operator should operate within the current context.
            test "Context" {
                const template_text = "'{{>partial}}'";
                const partials_template_text = .{
                    .{ "partial", "*{{text}}*" },
                };

                const expected = "'*content*'";

                var data = .{ .text = "content" };

                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // The greater-than operator should properly recurse.
            test "Recursion" {
                const Content = struct {
                    content: []const u8,
                    nodes: []const @This(),
                };

                const template_text = "{{>node}}";
                const partials_template_text = .{
                    .{ "node", "{{content}}<{{#nodes}}{{>node}}{{/nodes}}>" },
                };

                const expected = "X<Y<>>";

                var data = Content{ .content = "X", .nodes = &.{Content{ .content = "Y", .nodes = &.{} }} };
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // The greater-than operator should not alter surrounding whitespace.
            test "Surrounding Whitespace" {
                const template_text = "| {{>partial}} |";
                const partials_template_text = .{
                    .{ "partial", "\t|\t" },
                };

                const expected = "| \t|\t |";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // Whitespace should be left untouched.
            test "Inline Indentation" {
                const template_text = "  {{data}}  {{> partial}}\n";
                const partials_template_text = .{
                    .{ "partial", ">\n>" },
                };

                const expected = "  |  >\n>\n";

                var data = .{ .data = "|" };
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // "\r\n" should be considered a newline for standalone tags.
            test "Standalone Line Endings" {
                const template_text = "|\r\n{{>partial}}\r\n|";
                const partials_template_text = .{
                    .{ "partial", ">" },
                };

                const expected = "|\r\n>|";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // Standalone tags should not require a newline to precede them.
            test "Standalone Without Previous Line" {
                const template_text = "  {{>partial}}\n>";
                const partials_template_text = .{
                    .{ "partial", ">\n>" },
                };

                const expected = "  >\n  >>";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // Standalone tags should not require a newline to follow them.
            test "Standalone Without Newline" {
                const template_text = ">\n  {{>partial}}";
                const partials_template_text = .{
                    .{ "partial", ">\n>" },
                };

                const expected = ">\n  >\n  >";

                var data = .{};
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // Each line of the partial should be indented before rendering.
            test "Standalone indentation" {
                const template_text =
                    \\ \
                    \\  {{>partial}}
                    \\ /
                    \\
                ;

                const partials_template_text = .{
                    .{
                        "partial",
                        \\|
                        \\{{{content}}}
                        \\|
                        \\
                        ,
                    },
                };

                const expected =
                    \\ \
                    \\  |
                    \\  <
                    \\  ->
                    \\  |
                    \\ /
                    \\
                ;

                const data = .{ .content = "<\n->" };
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }

            // Superfluous in-tag whitespace should be ignored.
            test "Padding Whitespace" {
                const template_text = "|{{> partial }}|";
                const partials_template_text = .{
                    .{ "partial", "[]" },
                };

                const expected = "|[]|";

                var data = .{ .boolean = true };
                try expectRenderPartials(template_text, partials_template_text, data, expected);
            }
        };
    };

    const extra = struct {
        test "Emoji" {
            const template_text = "|👉={{emoji}}|";
            const expected = "|👉=👈|";

            var data = .{ .emoji = "👈" };
            try expectRender(template_text, data, expected);
        }

        test "Emoji as delimiter" {
            const template_text = "{{=👉 👈=}}👉message👈";
            const expected = "this is a message";

            var data = .{ .message = "this is a message" };
            try expectRender(template_text, data, expected);
        }

        test "UTF-8" {
            const template_text = "|mustache|{{arabic}}|{{japanese}}|{{russian}}|{{chinese}}|";
            const expected = "|mustache|شوارب|口ひげ|усы|胡子|";

            var data = .{ .arabic = "شوارب", .japanese = "口ひげ", .russian = "усы", .chinese = "胡子" };
            try expectRender(template_text, data, expected);
        }

        test "Context stack resolution" {
            const Data = struct {
                name: []const u8 = "root field",

                a: struct {
                    name: []const u8 = "a field",

                    a1: struct {
                        name: []const u8 = "a1 field",
                    } = .{},

                    pub fn lambda(ctx: LambdaContext) !void {
                        try ctx.write("a lambda");
                    }
                } = .{},

                b: struct {
                    pub fn lambda(ctx: LambdaContext) !void {
                        try ctx.write("b lambda");
                    }
                } = .{},

                pub fn lambda(ctx: LambdaContext) !void {
                    try ctx.write("root lambda");
                }
            };

            const template_text =
                \\{{! Correct paths should render fields and lambdas }}
                \\'{{a.name}}' == 'a field'
                \\'{{b.lambda}}' == 'b lambda'
                \\{{! Broken path should render empty strings }}
                \\'{{b.name}}' == ''
                \\'{{a.a1.lamabda}}' == ''
                \\{{! Sections should resolve fields and lambdas }}
                \\'{{#a}}{{name}}{{/a}}' == 'a field'
                \\'{{#b}}{{lambda}}{{/b}}' == 'b lambda'
                \\{{! Sections should lookup on the parent }}
                \\'{{#a}}{{#a1}}{{lambda}}{{/a1}}{{/a}}' == 'a lambda'
                \\'{{#b}}{{name}}{{/b}}' == 'root field'
            ;

            const expected_text =
                \\'a field' == 'a field'
                \\'b lambda' == 'b lambda'
                \\'' == ''
                \\'' == ''
                \\'a field' == 'a field'
                \\'b lambda' == 'b lambda'
                \\'a lambda' == 'a lambda'
                \\'root field' == 'root field'
            ;

            try expectRender(template_text, Data{}, expected_text);
        }

        test "Lambda - lower" {
            const Data = struct {
                name: []const u8,

                pub fn lower(ctx: LambdaContext) !void {
                    var text = try ctx.renderAlloc(testing.allocator, ctx.inner_text);
                    defer testing.allocator.free(text);

                    for (text) |char, i| {
                        text[i] = std.ascii.toLower(char);
                    }

                    try ctx.write(text);
                }
            };

            const template_text = "{{#lower}}Name={{name}}{{/lower}}";
            const expected = "name=phill";
            var data = Data{ .name = "Phill" };
            try expectRender(template_text, data, expected);
        }

        test "Lambda - nested" {
            const Data = struct {
                name: []const u8,

                pub fn lower(ctx: LambdaContext) !void {
                    var text = try ctx.renderAlloc(testing.allocator, ctx.inner_text);
                    defer testing.allocator.free(text);

                    for (text) |char, i| {
                        text[i] = std.ascii.toLower(char);
                    }

                    try ctx.write(text);
                }

                pub fn upper(ctx: LambdaContext) !void {
                    var text = try ctx.renderAlloc(testing.allocator, ctx.inner_text);
                    defer testing.allocator.free(text);

                    const expected = "name=phill";
                    try testing.expectEqualStrings(expected, text);

                    for (text) |char, i| {
                        text[i] = std.ascii.toUpper(char);
                    }

                    try ctx.write(text);
                }
            };

            const template_text = "{{#upper}}{{#lower}}Name={{name}}{{/lower}}{{/upper}}";
            const expected = "NAME=PHILL";
            var data = Data{ .name = "Phill" };
            try expectRender(template_text, data, expected);
        }

        test "Lambda - Pointer and Value" {
            const Person = struct {
                const Self = @This();

                first_name: []const u8,
                last_name: []const u8,

                pub fn name1(self: *Self, ctx: LambdaContext) !void {
                    try ctx.writeFormat("{s} {s}", .{ self.first_name, self.last_name });
                }

                pub fn name2(self: Self, ctx: LambdaContext) !void {
                    try ctx.writeFormat("{s} {s}", .{ self.first_name, self.last_name });
                }
            };

            const template_text = "Name1: {{name1}}, Name2: {{name2}}";
            var data = Person{ .first_name = "John", .last_name = "Smith" };

            // Value
            try expectRender(template_text, data, "Name1: , Name2: John Smith");

            // Pointer
            try expectRender(template_text, &data, "Name1: John Smith, Name2: John Smith");
        }

        test "Lambda - processing" {
            const Header = struct {
                id: u32,
                content: []const u8,

                pub fn hash(ctx: LambdaContext) !void {
                    var content = try ctx.renderAlloc(testing.allocator, ctx.inner_text);
                    defer testing.allocator.free(content);

                    const hash_value = std.hash.Crc32.hash(content);

                    try ctx.writeFormat("{}", .{hash_value});
                }
            };

            const template_text = "<header id='{{id}}' hash='{{#hash}}{{id}}{{content}}{{/hash}}'/>";

            var header = Header{ .id = 100, .content = "This is some content" };
            try expectRender(template_text, header, "<header id='100' hash='4174482081'/>");
        }

        test "Section Line breaks" {
            const template_text =
                \\TODO LIST
                \\{{#list}}
                \\- {{item}}
                \\{{/list}}
                \\DONE
            ;

            const expected =
                \\TODO LIST
                \\- 1
                \\- 2
                \\- 3
                \\DONE
            ;

            var data = .{
                .list = .{
                    .{ .item = 1 },
                    .{ .item = 2 },
                    .{ .item = 3 },
                },
            };
            try expectRender(template_text, data, expected);
        }

        test "Nested partials with indentation" {
            const template_text =
                \\BOF
                \\  {{>todo}}
                \\EOF
            ;

            const partials = .{
                .{
                    "todo",
                    \\My tasks
                    \\  {{>list}}
                    \\Done!
                    \\
                },

                .{
                    "list",
                    \\|id |desc    |
                    \\--------------
                    \\{{#list}}{{>item}}{{/list}}
                    \\--------------
                    \\
                },

                .{
                    "item",
                    \\|{{id}}  |{{desc}}  |
                    \\
                },
            };

            const expected =
                \\BOF
                \\  My tasks
                \\    |id |desc    |
                \\    --------------
                \\    |1  |task a  |
                \\    |2  |task b  |
                \\    |3  |task c  |
                \\    --------------
                \\  Done!
                \\EOF
            ;

            var data = .{
                .list = .{
                    .{ .id = 1, .desc = "task a" },
                    .{ .id = 2, .desc = "task b" },
                    .{ .id = 3, .desc = "task c" },
                },
            };

            try expectRenderPartials(template_text, partials, data, expected);
        }
    };

    const api = struct {
        test "render API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var couting_writer = std.io.countingWriter(std.io.null_writer);
            try mustache.render(template, .{ .hello = "hello " }, couting_writer.writer());

            try testing.expect(couting_writer.bytes_written == "hello world".len);
        }

        test "allocRender API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var ret = try mustache.allocRender(testing.allocator, template, .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "allocRenderZ API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var ret = try mustache.allocRenderZ(testing.allocator, template, .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "bufRender API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var buf: [11]u8 = undefined;
            var ret = try mustache.bufRender(&buf, template, .{ .hello = "hello " });

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "bufRenderZ API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var buf: [12]u8 = undefined;
            var ret = try mustache.bufRenderZ(&buf, template, .{ .hello = "hello " });

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "bufRender error API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var buf: [5]u8 = undefined;
            _ = mustache.bufRender(&buf, template, .{ .hello = "hello " }) catch |err| {
                try testing.expect(err == error.NoSpaceLeft);
                return;
            };

            try testing.expect(false);
        }

        test "bufRenderZ error API" {
            var template = try expectParseTemplate("{{hello}}world");
            defer template.deinit(testing.allocator);

            var buf: [11]u8 = undefined;
            _ = mustache.bufRenderZ(&buf, template, .{ .hello = "hello " }) catch |err| {
                try testing.expect(err == error.NoSpaceLeft);
                return;
            };

            try testing.expect(false);
        }

        test "renderText API" {
            var couting_writer = std.io.countingWriter(std.io.null_writer);
            try mustache.renderText(testing.allocator, "{{hello}}world", .{ .hello = "hello " }, couting_writer.writer());

            try testing.expect(couting_writer.bytes_written == "hello world".len);
        }

        test "allocRenderText API" {
            var ret = try mustache.allocRenderText(testing.allocator, "{{hello}}world", .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "allocRenderTextZ API" {
            var ret = try mustache.allocRenderTextZ(testing.allocator, "{{hello}}world", .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "renderFile API" {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            var absolute_path = try getTemplateFile(tmp.dir, "renderFile.mustache", "{{hello}}world");
            defer testing.allocator.free(absolute_path);

            var couting_writer = std.io.countingWriter(std.io.null_writer);
            try mustache.renderFile(testing.allocator, absolute_path, .{ .hello = "hello " }, couting_writer.writer());

            try testing.expect(couting_writer.bytes_written == "hello world".len);
        }

        test "allocRenderFile API" {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            var absolute_path = try getTemplateFile(tmp.dir, "allocRenderFile.mustache", "{{hello}}world");
            defer testing.allocator.free(absolute_path);

            var ret = try mustache.allocRenderFile(testing.allocator, absolute_path, .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }

        test "allocRenderFileZ API" {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();

            var absolute_path = try getTemplateFile(tmp.dir, "allocRenderFileZ.mustache", "{{hello}}world");
            defer testing.allocator.free(absolute_path);

            var ret = try mustache.allocRenderFileZ(testing.allocator, absolute_path, .{ .hello = "hello " });
            defer testing.allocator.free(ret);

            try testing.expectEqualStrings(ret, "hello world");
        }
    };

    const escape_tests = struct {
        const dummy_options = RenderOptions{ .Text = .{} };
        const DummyPartialsMap = map.PartialsMap(@TypeOf(.{ "foo", "bar" }), dummy_options);
        const Engine = RenderEngine(std.ArrayList(u8).Writer, DummyPartialsMap, dummy_options);
        const escapedWrite = Engine.escapedWrite;
        const unescapedWrite = Engine.unescapedWrite;
        const IndentationQueue = Engine.IndentationQueue;
        const Indentation = Engine.Indentation;

        test "Escape" {
            try expectEscape("&gt;abc", ">abc", .Escaped);
            try expectEscape("abc&lt;", "abc<", .Escaped);
            try expectEscape("&gt;abc&lt;", ">abc<", .Escaped);
            try expectEscape("ab&amp;cd", "ab&cd", .Escaped);
            try expectEscape("&gt;ab&amp;cd", ">ab&cd", .Escaped);
            try expectEscape("ab&amp;cd&lt;", "ab&cd<", .Escaped);
            try expectEscape("&gt;ab&amp;cd&lt;", ">ab&cd<", .Escaped);
            try expectEscape("&quot;ab&#39;&amp;&#39;cd&quot;",
                \\"ab'&'cd"
            , .Escaped);

            try expectEscape(">ab&cd<", ">ab&cd<", .Unescaped);
        }

        test "Escape and Indentation" {
            var root = IndentationQueue{};

            var node_1 = IndentationQueue.Node{
                .indentation = ">>",
                .last_indented_element = undefined,
            };
            var level_1 = root.indent(&node_1);

            try expectEscapeAndIndent("&gt;a\n>>&gt;b\n>>&gt;c", ">a\n>b\n>c", .Escaped, level_1.get(undefined));
            try expectEscapeAndIndent("&gt;a\r\n>>&gt;b\r\n>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_1.get(undefined));

            {
                var node_2 = IndentationQueue.Node{
                    .indentation = ">>",
                    .last_indented_element = undefined,
                };
                var level_2 = level_1.indent(&node_2);
                defer level_1.unindent();

                try expectEscapeAndIndent("&gt;a\n>>>>&gt;b\n>>>>&gt;c", ">a\n>b\n>c", .Escaped, level_2.get(undefined));
                try expectEscapeAndIndent("&gt;a\r\n>>>>&gt;b\r\n>>>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_2.get(undefined));
            }

            try expectEscapeAndIndent("&gt;a\n>>&gt;b\n>>&gt;c", ">a\n>b\n>c", .Escaped, level_1.get(undefined));
            try expectEscapeAndIndent("&gt;a\r\n>>&gt;b\r\n>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_1.get(undefined));
        }

        test "Indentation" {
            var root = IndentationQueue{};

            var node_1 = IndentationQueue.Node{
                .indentation = ">>",
                .last_indented_element = undefined,
            };
            var level_1 = root.indent(&node_1);

            try expectIndent("a\n>>b\n>>c", "a\nb\nc", level_1.get(undefined));
            try expectIndent("a\r\n>>b\r\n>>c", "a\r\nb\r\nc", level_1.get(undefined));

            {
                var node_2 = IndentationQueue.Node{
                    .indentation = ">>",
                    .last_indented_element = undefined,
                };
                var level_2 = level_1.indent(&node_2);
                defer level_1.unindent();

                try expectIndent("a\n>>>>b\n>>>>c", "a\nb\nc", level_2.get(undefined));
                try expectIndent("a\r\n>>>>b\r\n>>>>c", "a\r\nb\r\nc", level_2.get(undefined));
            }

            try expectIndent("a\n>>b\n>>c", "a\nb\nc", level_1.get(undefined));
            try expectIndent("a\r\n>>b\r\n>>c", "a\r\nb\r\nc", level_1.get(undefined));
        }

        fn expectEscape(expected: []const u8, value: []const u8, escape: Escape) !void {
            const allocator = testing.allocator;
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();

            var written_bytes = try escapedWrite(list.writer(), value, escape, .{});
            try testing.expectEqualStrings(expected, list.items);
            try testing.expectEqual(expected.len, written_bytes);
        }

        fn expectIndent(expected: []const u8, value: []const u8, indentation: Indentation) !void {
            const allocator = testing.allocator;
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();

            var written_bytes = try escapedWrite(list.writer(), value, .Unescaped, indentation);
            try testing.expectEqualStrings(expected, list.items);
            try testing.expectEqual(expected.len, written_bytes);
        }

        fn expectEscapeAndIndent(expected: []const u8, value: []const u8, escape: Escape, indentation: Indentation) !void {
            const allocator = testing.allocator;
            var list = std.ArrayList(u8).init(allocator);
            defer list.deinit();

            var written_bytes = try escapedWrite(list.writer(), value, escape, indentation);
            try testing.expectEqualStrings(expected, list.items);
            try testing.expectEqual(expected.len, written_bytes);
        }
    };

    fn expectRender(template_text: []const u8, data: anytype, expected: []const u8) anyerror!void {
        try expectCachedRender(template_text, data, expected);
        try expectStreamedRender(template_text, data, expected);
    }

    fn expectRenderPartials(template_text: []const u8, partials: anytype, data: anytype, expected: []const u8) anyerror!void {
        try expectCachedRenderPartials(template_text, partials, data, expected);
        try expectStreamedRenderPartials(template_text, partials, data, expected);
    }

    fn expectParseTemplate(template_text: []const u8) !Template {
        const allocator = testing.allocator;

        // Cached template render
        switch (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false })) {
            .ParseError => {
                try testing.expect(false);
                unreachable;
            },
            .Success => |ret| return ret,
        }
    }

    fn expectCachedRender(template_text: []const u8, data: anytype, expected: []const u8) anyerror!void {
        const allocator = testing.allocator;

        // Cached template render
        var cached_template = try expectParseTemplate(template_text);
        defer cached_template.deinit(allocator);

        var result = try allocRender(allocator, cached_template, data);
        defer allocator.free(result);
        try testing.expectEqualStrings(expected, result);
    }

    fn expectCachedRenderPartials(template_text: []const u8, partials: anytype, data: anytype, expected: []const u8) anyerror!void {
        const allocator = testing.allocator;

        // Cached template render
        var cached_template = try expectParseTemplate(template_text);
        defer cached_template.deinit(allocator);

        var hashMap = std.StringHashMap(Template).init(allocator);
        defer {
            var iterator = hashMap.valueIterator();
            while (iterator.next()) |partial| {
                partial.deinit(allocator);
            }
            hashMap.deinit();
        }

        inline for (partials) |item| {
            var partial_template = try expectParseTemplate(item[1]);
            errdefer partial_template.deinit(allocator);

            try hashMap.put(item[0], partial_template);
        }

        var result = try allocRenderPartials(allocator, cached_template, hashMap, data);
        defer allocator.free(result);

        try testing.expectEqualStrings(expected, result);
    }

    fn expectStreamedRenderPartials(template_text: []const u8, partials: anytype, data: anytype, expected: []const u8) anyerror!void {
        const allocator = testing.allocator;

        var result = try allocRenderTextPartials(allocator, template_text, partials, data);
        defer allocator.free(result);

        try testing.expectEqualStrings(expected, result);
    }

    fn expectStreamedRender(template_text: []const u8, data: anytype, expected: []const u8) anyerror!void {
        const allocator = testing.allocator;

        // Streamed template render
        var result = try allocRenderText(allocator, template_text, data);
        defer allocator.free(result);

        try testing.expectEqualStrings(expected, result);
    }

    fn getTemplateFile(dir: std.fs.Dir, file_name: []const u8, template_text: []const u8) ![]const u8 {
        var file = try dir.createFile(file_name, .{ .truncate = true });
        defer file.close();

        try file.writeAll(template_text);

        return try dir.realpathAlloc(testing.allocator, file_name);
    }
};
