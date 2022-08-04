const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;
const TemplateSource = mustache.options.TemplateSource;
const TemplateLoadMode = mustache.options.TemplateLoadMode;
const Features = mustache.options.Features;

const parsing = @import("parsing/parsing.zig");

pub const Delimiters = parsing.Delimiters;

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedCloseSection,
    InvalidDelimiters,
    InvalidIdentifier,
    ClosingTagMismatch,
};

pub const ParseErrorDetail = struct {
    parse_error: ParseError,
    lin: u32 = 0,
    col: u32 = 0,
};

pub const ParseResult = union(enum) {
    parse_error: ParseErrorDetail,
    success: Template,
};

pub const Element = union(Element.Type) {
    static_text: []const u8,
    interpolation: Path,
    unescaped_interpolation: Path,
    section: Section,
    inverted_section: InvertedSection,
    partial: Partial,
    parent: Parent,
    block: Block,

    pub const Path = []const []const u8;

    pub const Type = enum {
        /// Static text
        static_text,

        ///  Interpolation tags are used to integrate dynamic content into the template.
        ///
        ///  The tag's content MUST be a non-whitespace character sequence NOT containing
        ///  the current closing delimiter.
        ///
        ///  This tag's content names the data to replace the tag.
        ///  A single period (`.`) indicates that the item currently sitting atop the context stack should be
        ///  used; otherwise, name resolution is as follows:
        ///
        ///    1) Split the name on periods; the first part is the name to resolve, any
        ///    remaining parts should be retained.
        ///
        ///    2) Walk the context stack from top to bottom, finding the first context
        ///    that is a) a hash containing the name as a key OR b) an object responding
        ///    to a method with the given name.
        ///
        ///    3) If the context is a hash, the data is the value associated with the
        ///    name.
        ///
        ///    4) If the context is an object, the data is the value returned by the
        ///    method with the given name.
        ///
        ///    5) If any name parts were retained in step 1, each should be resolved
        ///    against a context stack containing only the result from the former
        ///    resolution.  If any part fails resolution, the result should be considered
        ///    falsey, and should interpolate as the empty string.
        ///
        ///  Data should be coerced into a string (and escaped, if appropriate) before
        ///  interpolation.
        ///
        ///  The Interpolation tags MUST NOT be treated as standalone.
        interpolation,
        unescaped_interpolation,

        ///  Section tags and End Section tags are used in combination to wrap a section
        ///  of the template for iteration
        ///
        ///  These tags' content MUST be a non-whitespace character sequence NOT
        ///  containing the current closing delimiter; each Section tag MUST be followed
        ///  by an End Section tag with the same content within the same section.
        ///
        ///  This tag's content names the data to replace the tag.
        ///  Name resolution is as follows:
        ///
        ///    1) Split the name on periods; the first part is the name to resolve, any
        ///    remaining parts should be retained.
        ///
        ///    2) Walk the context stack from top to bottom, finding the first context
        ///    that is a) a hash containing the name as a key OR b) an object responding
        ///    to a method with the given name.
        ///
        ///    3) If the context is a hash, the data is the value associated with the
        ///    name.
        ///
        ///    4) If the context is an object and the method with the given name has an
        ///    arity of 1, the method SHOULD be called with a String containing the
        ///    unprocessed contents of the sections; the data is the value returned.
        ///
        ///    5) Otherwise, the data is the value returned by calling the method with
        ///    the given name.
        ///
        ///    6) If any name parts were retained in step 1, each should be resolved
        ///    against a context stack containing only the result from the former
        ///    resolution.  If any part fails resolution, the result should be considered
        ///    falsey, and should interpolate as the empty string.
        ///
        ///  If the data is not of a list type, it is coerced into a list as follows: if
        ///  the data is truthy (e.g. `!!data == true`), use a single-element list
        ///  containing the data, otherwise use an empty list.
        ///
        ///  For each element in the data list, the element MUST be pushed onto the
        ///  context stack, the section MUST be rendered, and the element MUST be popped
        ///  off the context stack.
        ///
        ///  Section and End Section tags SHOULD be treated as standalone when appropriate.
        section,
        inverted_section,

        /// Partial tags are used to expand an external template into the current
        /// template.
        ///
        /// The tag's content MUST be a non-whitespace character sequence NOT containing
        /// the current closing delimiter.
        ///
        /// This tag's content names the partial to inject.  Set Delimiter tags MUST NOT
        /// affect the parsing of a partial.
        /// The partial MUST be rendered against the context stack local to the tag.
        /// If the named partial cannot be found, the empty string SHOULD be used instead, as in interpolations.
        ///
        /// Partial tags SHOULD be treated as standalone when appropriate.
        /// If this tag is used standalone, any whitespace preceding the tag should treated as
        /// indentation, and prepended to each line of the partial before rendering.
        partial,

        ///  Like partials, Parent tags are used to expand an external template into the
        ///  current template. Unlike partials, Parent tags may contain optional
        ///  arguments delimited by Block tags. For this reason, Parent tags may also be
        ///  referred to as Parametric Partials.
        ///
        ///  The Parent tags' content MUST be a non-whitespace character sequence NOT
        ///  containing the current closing delimiter; each Parent tag MUST be followed by
        ///  an End Section tag with the same content within the matching Parent tag.
        ///
        ///  This tag's content names the Parent template to inject.
        ///  Set Delimiter tags Preceding a Parent tag MUST NOT affect the parsing of the injected external
        ///  template. The Parent MUST be rendered against the context stack local to the tag.
        ///
        ///  If the named Parent cannot be found, the empty string SHOULD be used instead, as in interpolations.
        ///
        ///  Parent tags SHOULD be treated as standalone when appropriate.
        ///  If this tag is used standalone, any whitespace preceding the tag should be treated as
        ///  indentation, and prepended to each line of the Parent before rendering.
        parent,

        /// The Block tags' content MUST be a non-whitespace character sequence NOT
        /// containing the current closing delimiter.
        ///
        /// Each Block tag MUST be followed by an End Section tag with the same content within the matching Block tag.
        /// This tag's content determines the parameter or argument name.
        ///
        /// Block tags may appear both inside and outside of Parent tags. In both cases,
        /// they specify a position within the template that can be overridden; it is a
        /// parameter of the containing template.
        ///
        /// The template text between the Block tag and its matching End Section tag
        /// defines the default content to render when the parameter is not overridden from outside.
        ///
        /// In addition, when used inside of a Parent tag,
        /// the template text between a Block tag and its matching End Section tag defines
        /// content that replaces the default defined in the Parent template.
        ///
        /// This content is the argument passed to the Parent template.
        block,
    };

    pub const Section = struct {
        path: Path,
        children_count: u32,
        inner_text: ?[]const u8,
        delimiters: ?Delimiters,
    };

    pub const InvertedSection = struct {
        path: Path,
        children_count: u32,
    };

    pub const Partial = struct {
        key: []const u8,
        indentation: ?[]const u8,
    };

    pub const Parent = struct {
        key: []const u8,
        children_count: u32,
        indentation: ?[]const u8,
    };

    pub const Block = struct {
        key: []const u8,
        children_count: u32,
    };

    pub fn deinit(self: Element, allocator: Allocator, owns_string: bool) void {
        switch (self) {
            .static_text => |content| if (owns_string) allocator.free(content),
            .interpolation => |path| destroyPath(allocator, owns_string, path),
            .unescaped_interpolation => |path| destroyPath(allocator, owns_string, path),
            .section => |section| {
                destroyPath(allocator, owns_string, section.path);
                if (owns_string) {
                    if (section.inner_text) |inner_text| allocator.free(inner_text);
                }
            },
            .inverted_section => |section| {
                destroyPath(allocator, owns_string, section.path);
            },
            .partial => |partial| {
                if (owns_string) {
                    allocator.free(partial.key);
                    if (partial.indentation) |indentation| allocator.free(indentation);
                }
            },

            .parent => |parent| {
                if (owns_string) allocator.free(parent.key);
            },

            .block => |block| {
                if (owns_string) allocator.free(block.key);
            },
        }
    }

    pub fn deinitMany(allocator: Allocator, owns_string: bool, items: []const Element) void {
        for (items) |item| {
            item.deinit(allocator, owns_string);
        }
    }

    pub inline fn destroyPath(allocator: Allocator, owns_string: bool, path: Path) void {
        if (path.len > 0) {
            if (owns_string) {
                for (path) |part| allocator.free(part);
            }
            allocator.free(path);
        }
    }
};

pub const Template = struct {
    elements: []const Element,
    options: *const TemplateOptions,

    pub fn deinit(self: Template, allocator: Allocator) void {
        if (self.options.load_mode == .runtime_loaded) {
            Element.deinitMany(allocator, self.options.copyStrings(), self.elements);
            allocator.free(self.elements);
        }
    }
};

/// Parses a string and returns an union containing either a `ParseError` or a `Template`
/// parameters:
/// `allocator` used to all temporary and permanent allocations.
///   Use this same allocator to deinit the returned template
/// `template_text`: utf-8 encoded template text to be parsed
/// `default_delimiters`: define custom delimiters, or use .{} for the default
/// `options`: comptime options.
pub fn parseText(
    allocator: Allocator,
    template_text: []const u8,
    default_delimiters: Delimiters,
    comptime options: mustache.options.ParseTextOptions,
) Allocator.Error!ParseResult {
    const source = TemplateSource{ .string = .{ .copy_strings = options.copy_strings } };
    return try parseSource(
        source,
        options.features,
        allocator,
        template_text,
        default_delimiters,
        .runtime_loaded,
    );
}

/// Parses a comptime string a `Template`
pub fn parseComptime(
    comptime template_text: []const u8,
    comptime default_delimiters: Delimiters,
    comptime features: mustache.options.Features,
) Template {
    comptime {
        @setEvalBranchQuota(999999);
        const source = TemplateSource{ .string = .{ .copy_strings = false } };
        const unused: Allocator = undefined;
        const parse_result = parseSource(
            source,
            features,
            unused,
            template_text,
            default_delimiters,
            .{
                .comptime_loaded = .{
                    .template_text = template_text,
                    .default_delimiters = default_delimiters,
                },
            },
        ) catch unreachable;

        return switch (parse_result) {
            .success => |template| template,
            .parse_error => |detail| {
                const message = std.fmt.comptimePrint("Parse error {s} at lin {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
                @compileError(message);
            },
        };
    }
}

/// Parses a file and returns an union containing either a `ParseError` or a `Template`
/// parameters:
/// `allocator` used to all temporary and permanent allocations.
///   Use this same allocator to deinit the returned template
/// `template_text`: utf-8 encoded template text to be parsed
/// `default_delimiters`: define custom delimiters, or use .{} for the default
/// `options`: comptime options.
pub fn parseFile(
    allocator: Allocator,
    template_absolute_path: []const u8,
    default_delimiters: Delimiters,
    comptime options: mustache.options.ParseFileOptions,
) (Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError)!ParseResult {
    const source = TemplateSource{ .file = .{ .read_buffer_size = options.read_buffer_size } };
    return try parseSource(
        source,
        options.features,
        allocator,
        template_absolute_path,
        default_delimiters,
        .runtime_loaded,
    );
}

fn parseSource(
    comptime source: TemplateSource,
    comptime features: Features,
    allocator: Allocator,
    source_content: []const u8,
    delimiters: Delimiters,
    comptime load_mode: TemplateLoadMode,
) !ParseResult {
    const options = TemplateOptions{
        .source = source,
        .output = .cache,
        .features = features,
        .load_mode = load_mode,
    };

    var template = TemplateLoader(options){
        .allocator = allocator,
        .delimiters = delimiters,
    };

    errdefer template.deinit();
    try template.load(source_content);

    switch (template.result) {
        .elements => |elements| return ParseResult{ .success = .{ .elements = elements, .options = &options } },
        .parser_error => |last_error| return ParseResult{ .parse_error = last_error },
        .not_loaded => unreachable,
    }
}

pub fn TemplateLoader(comptime options: TemplateOptions) type {
    return struct {
        const Self = @This();

        const Parser = parsing.Parser(options);
        const Node = Parser.Node;

        const Collector = struct {
            pub const Error = error{};

            elements: []Element = &.{},

            pub inline fn render(ctx: *@This(), elements: []Element) Error!void {
                ctx.elements = elements;
            }
        };

        allocator: Allocator,
        delimiters: Delimiters = .{},
        result: union(enum) {
            not_loaded,
            elements: []const Element,
            parser_error: ParseErrorDetail,
        } = .not_loaded,

        pub fn load(self: *Self, template: []const u8) Parser.LoadError!void {
            var parser = try Parser.init(self.allocator, template, self.delimiters);
            defer parser.deinit();

            var collector = Collector{};
            var success = try parser.parse(&collector);

            self.result = if (success) .{
                .elements = collector.elements,
            } else .{
                .parser_error = parser.last_error.?,
            };
        }

        pub fn collectElements(self: *Self, template_text: []const u8, render: anytype) ErrorSet(Parser, @TypeOf(render))!void {
            var parser = try Parser.init(self.allocator, template_text, self.delimiters);
            defer parser.deinit();

            _ = try parser.parse(render);
        }

        pub fn deinit(self: *Self) void {
            if (options.load_mode == .runtime_loaded) {
                switch (self.result) {
                    .elements => |elements| {
                        Element.deinitMany(self.allocator, options.copyStrings(), elements);
                        self.allocator.free(elements);
                    },
                    .parser_error, .not_loaded => {},
                }
            }
        }

        fn ErrorSet(comptime TParser: type, comptime TRender: type) type {
            const parserInfo = @typeInfo(TParser);
            const renderInfo = @typeInfo(TRender);

            const ParserError = switch (parserInfo) {
                .Struct => TParser.LoadError,
                .Pointer => |info| if (info.size == .One) info.child.LoadError else @compileError("expected a reference to a parser, found " ++ @typeName(TParser)),
                else => @compileError("expected a parser, found " ++ @typeName(TParser)),
            };

            const RenderError = switch (renderInfo) {
                .Struct => TRender.Error,
                .Pointer => |info| if (info.size == .One) info.child.Error else @compileError("expected a reference to a render, found " ++ @typeName(TParser)),
                else => @compileError("expected a render, found " ++ @typeName(TParser)),
            };

            return ParserError || RenderError;
        }
    };
}

test {
    _ = tests;
    _ = parsing;
}

const tests = struct {
    test {
        _ = comments;
        _ = delimiters;
        _ = interpolation;
        _ = sections;
        _ = inverted;
        _ = partials_section;
        _ = lambdas;
        _ = extra;
        _ = api;
    }

    fn TesterTemplateLoader(comptime load_mode: TemplateLoadMode) type {
        const options = TemplateOptions{
            .source = .{ .string = .{ .copy_strings = false } },
            .output = .cache,
            .load_mode = load_mode,
        };

        return TemplateLoader(options);
    }

    pub fn getTemplate(template_text: []const u8, comptime load_mode: TemplateLoadMode) !TesterTemplateLoader(load_mode) {
        const allocator = testing.allocator;

        var template_loader = TesterTemplateLoader(load_mode){
            .allocator = allocator,
        };
        errdefer template_loader.deinit();

        try template_loader.load(template_text);

        if (template_loader.result == .parser_error) {
            const detail = template_loader.result.parser_error;

            if (load_mode == .runtime_loaded) {
                std.log.err("{s} row {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            }

            return detail.parse_error;
        }

        return template_loader;
    }

    pub fn expectPath(expected: []const u8, path: Element.Path) !void {
        const TestParser = TesterTemplateLoader(.runtime_loaded).Parser;
        var parser = try TestParser.init(testing.allocator, "", .{});
        defer parser.deinit();

        const expected_path = try parser.parsePath(expected);
        defer Element.destroyPath(testing.allocator, false, expected_path);

        try testing.expectEqual(expected_path.len, path.len);
        for (expected_path) |expected_part, i| {
            try testing.expectEqualStrings(expected_part, path[i]);
        }
    }

    const comments = struct {

        //
        // Comment blocks should be removed from the template.
        test "Inline" {
            const template_text = "12345{{! Comment Block! }}67890";

            const runTheTest = struct {
                pub fn action(comptime load_mode: TemplateLoadMode) !void {
                    var template = try getTemplate(template_text, load_mode);
                    defer template.deinit();

                    const elements = template.result.elements;

                    try testing.expectEqual(@as(usize, 2), elements.len);

                    try testing.expectEqual(Element.Type.static_text, elements[0]);
                    try testing.expectEqualStrings("12345", elements[0].static_text);

                    try testing.expectEqual(Element.Type.static_text, elements[1]);
                    try testing.expectEqualStrings("67890", elements[1].static_text);
                }
            }.action;

            try runTheTest(.runtime_loaded);
            comptime {
                try runTheTest(.{
                    .comptime_loaded = .{
                        .template_text = template_text,
                        .default_delimiters = .{},
                    },
                });
            }
        }

        //
        // Multiline comments should be permitted.
        test "Multiline" {
            const template_text =
                \\12345{{!
                \\  This is a
                \\  multi-line comment...
                \\}}67890
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("12345", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("67890", elements[1].static_text);
        }

        //
        // All standalone comment lines should be removed.
        test "Standalone" {
            const template_text =
                \\Begin.
                \\{{! Comment Block! }}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // All standalone comment lines should be removed.
        test "Indented Standalone" {
            const template_text =
                \\Begin.
                \\    {{! Indented Comment Block! }}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{! Standalone Comment }}\r\n|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);

            try testing.expectEqualStrings("|", elements[1].static_text);
        }

        //
        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "!\n  {{! I'm Still Standalone }}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("!\n", elements[0].static_text);
        }

        //
        // All standalone comment lines should be removed.
        test "Multiline Standalone" {
            const template_text =
                \\Begin.
                \\{{!
                \\Something's going on here... 
                \\}}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // All standalone comment lines should be removed.
        test "Indented Multiline Standalone" {
            const template_text =
                \\Begin.
                \\  {{!
                \\    Something's going on here... 
                \\  }}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // Inline comments should not strip whitespace.
        test "Indented Inline" {
            const template_text = "  12 {{! 34 }}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  12 ", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("\n", elements[1].static_text);
        }

        //
        // Comment removal should preserve surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "12345 {{! Comment Block! }} 67890";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("12345 ", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings(" 67890", elements[1].static_text);
        }
    };

    const delimiters = struct {

        //
        // The equals sign (used on both sides) should permit delimiter changes.
        test "Pair Behavior" {
            const template_text = "{{=<% %>=}}(<%text%>)";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("(", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("text", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(")", elements[2].static_text);
        }

        //
        // Characters with special meaning regexen should be valid delimiters.
        test "Special Characters" {
            const template_text = "({{=[ ]=}}[text])";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("(", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("text", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(")", elements[2].static_text);
        }

        //
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

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 10), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("section", elements[1].section.path);
            try testing.expectEqual(@as(usize, 3), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[3]);
            try expectPath("data", elements[3].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings("\n  |data|\n", elements[4].static_text);

            // Delimiters changed

            try testing.expectEqual(Element.Type.section, elements[5]);
            try expectPath("section", elements[5].section.path);
            try testing.expectEqual(@as(usize, 3), elements[5].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("  {{data}}\n  ", elements[6].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[7]);
            try expectPath("data", elements[7].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[8]);
            try testing.expectEqualStrings("\n", elements[8].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[9]);
            try testing.expectEqualStrings("]", elements[9].static_text);
        }

        //
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

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 10), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("section", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 3), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[3]);
            try expectPath("data", elements[3].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings("\n  |data|\n", elements[4].static_text);

            // Delimiters changed

            try testing.expectEqual(Element.Type.inverted_section, elements[5]);
            try expectPath("section", elements[5].inverted_section.path);
            try testing.expectEqual(@as(usize, 3), elements[5].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("  {{data}}\n  ", elements[6].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[7]);
            try expectPath("data", elements[7].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[8]);
            try testing.expectEqualStrings("\n", elements[8].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[9]);
            try testing.expectEqualStrings("]", elements[9].static_text);
        }

        //
        // Surrounding whitespace should be left untouched.
        test "Surrounding Whitespace" {
            const template_text = "| {{=@ @=}} |";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings(" |", elements[1].static_text);
        }

        //
        // Whitespace should be left untouched.
        test "Outlying Whitespace (Inline)" {
            const template_text = " | {{=@ @=}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("\n", elements[1].static_text);
        }

        //
        // Standalone lines should be removed from the template.
        test "Standalone Tag" {
            const template_text =
                \\Begin.
                \\{{=@ @=}}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Tag" {
            const template_text =
                \\Begin.
                \\{{=@ @=}}
                \\End.
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].static_text);
        }

        //
        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{= @ @ =}}\r\n|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("|", elements[1].static_text);
        }

        //
        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{=@ @=}}\n=";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("=", elements[0].static_text);
        }

        //
        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "=\n  {{=@ @=}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("=\n", elements[0].static_text);
        }

        //
        // Superfluous in-tag whitespace should be ignored.
        test "Pair with Padding" {
            const template_text = "|{{= @   @ =}}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("|", elements[1].static_text);
        }
    };

    const interpolation = struct {

        // Mustache-free templates should render as-is.
        test "No Interpolation" {
            const template_text = "Hello from {Mustache}!";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Hello from {Mustache}!", elements[0].static_text);
        }

        // Unadorned tags should interpolate content into the template.
        test "Basic Interpolation" {
            const template_text = "Hello, {{subject}}!";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("Hello, ", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("subject", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("!", elements[2].static_text);
        }

        // Basic interpolation should be HTML escaped.
        test "HTML Escaping" {
            const template_text = "These characters should be HTML escaped: {{forbidden}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("These characters should be HTML escaped: ", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("forbidden", elements[1].interpolation);
        }

        // Triple mustaches should interpolate without HTML escaping.
        test "Triple Mustache" {
            const template_text = "These characters should not be HTML escaped: {{{forbidden}}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("forbidden", elements[1].unescaped_interpolation);
        }

        // Ampersand should interpolate without HTML escaping.
        test "Ampersand" {
            const template_text = "These characters should not be HTML escaped: {{&forbidden}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("forbidden", elements[1].unescaped_interpolation);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Interpolation - Surrounding Whitespace" {
            const template_text = "| {{string}} |";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("string", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].static_text);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Surrounding Whitespace" {
            const template_text = "| {{{string}}} |";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].static_text);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Ampersand - Surrounding Whitespace" {
            const template_text = "| {{&string}} |";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].static_text);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Interpolation - Standalone" {
            const template_text = "  {{string}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("string", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].static_text);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Standalone" {
            const template_text = "  {{{string}}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].static_text);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Ampersand - Standalone" {
            const template_text = "  {{&string}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Interpolation With Padding" {
            const template_text = "|{{ string }}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("string", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Triple Mustache With Padding" {
            const template_text = "|{{{ string }}}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Ampersand With Padding" {
            const template_text = "|{{& string }}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[1]);
            try expectPath("string", elements[1].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }
    };

    const sections = struct {

        // Sections should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = " | {{#boolean}}\t|\t{{/boolean}} | \n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\t|\t", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings(" | \n", elements[3].static_text);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{#boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 2), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" ", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings(" | \n", elements[4].static_text);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{#boolean}}YES{{/boolean}}\n {{#boolean}}GOOD{{/boolean}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 7), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("YES", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].static_text);

            try testing.expectEqual(Element.Type.section, elements[4]);
            try expectPath("boolean", elements[4].section.path);
            try testing.expectEqual(@as(usize, 1), elements[4].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[5]);
            try testing.expectEqualStrings("GOOD", elements[5].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].static_text);
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

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].static_text);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{#boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 0), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{#boolean}}\n#{{/boolean}}\n/";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.section, elements[0]);
            try expectPath("boolean", elements[0].section.path);
            try testing.expectEqual(@as(usize, 1), elements[0].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("#", elements[1].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n/", elements[2].static_text);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "#{{#boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("#", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n/\n", elements[2].static_text);
        }

        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text =
                \\| This Is
                \\		{{#boolean}}
                \\|
                \\		{{/boolean}}
                \\| A Line
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{# boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("boolean", elements[1].section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("=", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("|", elements[3].static_text);
        }

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

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 77), elements.len);

            try testing.expectEqual(Element.Type.section, elements[0]);
            try expectPath("a", elements[0].section.path);

            {
                try testing.expectEqual(@as(usize, 76), elements[0].section.children_count);

                try testing.expectEqual(Element.Type.interpolation, elements[1]);
                try expectPath("one", elements[1].interpolation);

                try testing.expectEqual(Element.Type.static_text, elements[2]);
                try testing.expectEqualStrings("\n", elements[2].static_text);

                try testing.expectEqual(Element.Type.section, elements[3]);
                try expectPath("b", elements[3].section.path);

                {
                    try testing.expectEqual(@as(usize, 71), elements[3].section.children_count);

                    try testing.expectEqual(Element.Type.interpolation, elements[4]);
                    try expectPath("one", elements[4].interpolation);

                    try testing.expectEqual(Element.Type.interpolation, elements[5]);
                    try expectPath("two", elements[5].interpolation);

                    try testing.expectEqual(Element.Type.interpolation, elements[6]);
                    try expectPath("one", elements[6].interpolation);

                    try testing.expectEqual(Element.Type.static_text, elements[7]);
                    try testing.expectEqualStrings("\n", elements[7].static_text);

                    try testing.expectEqual(Element.Type.section, elements[8]);
                    try expectPath("c", elements[8].section.path);

                    {
                        try testing.expectEqual(@as(usize, 62), elements[8].section.children_count);
                        // Too lazy to do the rest ... 🙃
                    }

                    try testing.expectEqual(Element.Type.interpolation, elements[71]);
                    try expectPath("one", elements[71].interpolation);

                    try testing.expectEqual(Element.Type.interpolation, elements[72]);
                    try expectPath("two", elements[72].interpolation);

                    try testing.expectEqual(Element.Type.interpolation, elements[73]);
                    try expectPath("one", elements[73].interpolation);

                    try testing.expectEqual(Element.Type.static_text, elements[74]);
                    try testing.expectEqualStrings("\n", elements[74].static_text);
                }

                try testing.expectEqual(Element.Type.interpolation, elements[75]);
                try expectPath("one", elements[75].interpolation);

                try testing.expectEqual(Element.Type.static_text, elements[76]);
                try testing.expectEqualStrings("\n", elements[76].static_text);
            }
        }
    };

    const inverted = struct {

        // Sections should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = " | {{^boolean}}\t|\t{{/boolean}} | \n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\t|\t", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings(" | \n", elements[3].static_text);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{^boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 2), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" ", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings(" | \n", elements[4].static_text);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{^boolean}}NO{{/boolean}}\n {{^boolean}}WAY{{/boolean}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 7), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("NO", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[4]);
            try expectPath("boolean", elements[4].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[4].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[5]);
            try testing.expectEqualStrings("WAY", elements[5].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].static_text);
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

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].static_text);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{^boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 0), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{^boolean}}\n^{{/boolean}}\n/";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.inverted_section, elements[0]);
            try expectPath("boolean", elements[0].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[0].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings("^", elements[1].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n/", elements[2].static_text);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "^{{^boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("^", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("\n/\n", elements[2].static_text);
        }

        // Standalone indented lines should be removed from the template.
        test "Standalone Indented Lines" {
            const template_text =
                \\| This Is
                \\		{{^boolean}}
                \\|
                \\		{{/boolean}}
                \\| A Line
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{^ boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[1]);
            try expectPath("boolean", elements[1].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("=", elements[2].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings("|", elements[3].static_text);
        }
    };

    const partials_section = struct {

        // The greater-than operator should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "| {{>partial}} |";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].static_text);

            try testing.expectEqual(Element.Type.partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].partial.key);
            try testing.expect(elements[1].partial.indentation == null);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].static_text);
        }

        // Whitespace should be left untouched.
        test "Inline Indentation" {
            const template_text = "  {{data}}  {{> partial}}\n";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[1]);
            try expectPath("data", elements[1].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].static_text);

            try testing.expectEqual(Element.Type.partial, elements[3]);
            try testing.expectEqualStrings("partial", elements[3].partial.key);
            try testing.expect(elements[3].partial.indentation == null);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings("\n", elements[4].static_text);
        }

        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{>partial}}\r\n|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].partial.key);
            try testing.expect(elements[1].partial.indentation == null);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{>partial}}\n>";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.partial, elements[0]);
            try testing.expectEqualStrings("partial", elements[0].partial.key);
            try testing.expect(elements[0].partial.indentation != null);
            try testing.expectEqualStrings("  ", elements[0].partial.indentation.?);

            try testing.expectEqual(Element.Type.static_text, elements[1]);
            try testing.expectEqualStrings(">", elements[1].static_text);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = ">\n  {{>partial}}";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings(">\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].partial.key);
            try testing.expect(elements[1].partial.indentation != null);
            try testing.expectEqualStrings("  ", elements[1].partial.indentation.?);
        }

        // Each line of the partial should be indented before rendering.
        test "Standalone Indentation" {
            const template_text =
                \\  \
                \\   {{>partial}}
                \\  /
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  \\\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].partial.key);
            try testing.expect(elements[1].partial.indentation != null);
            try testing.expectEqualStrings("   ", elements[1].partial.indentation.?);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("  /", elements[2].static_text);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{> partial }}|";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("|", elements[0].static_text);

            try testing.expectEqual(Element.Type.partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].partial.key);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("|", elements[2].static_text);
        }
    };

    const lambdas = struct {

        // Lambdas used for sections should receive the raw section string.
        test "Sections" {
            const template_text = "<{{#lambda}}{{x}}{{/lambda}}>";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("<", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("lambda", elements[1].section.path);
            try testing.expect(elements[1].section.inner_text != null);
            try testing.expectEqualStrings("{{x}}", elements[1].section.inner_text.?);
            try testing.expectEqual(@as(usize, 1), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.interpolation, elements[2]);
            try expectPath("x", elements[2].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[3]);
            try testing.expectEqualStrings(">", elements[3].static_text);
        }

        // Lambdas used for sections should receive the raw section string.
        test "Nested Sections" {
            const template_text = "<{{#lambda}}{{#lambda2}}{{x}}{{/lambda2}}{{/lambda}}>";

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("<", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);

            const section = elements[1].section;
            try expectPath("lambda", section.path);
            try testing.expect(section.inner_text != null);
            try testing.expectEqualStrings("{{#lambda2}}{{x}}{{/lambda2}}", section.inner_text.?);
            try testing.expectEqual(@as(usize, 2), section.children_count);

            try testing.expectEqual(Element.Type.section, elements[2]);
            const sub_section = elements[2].section;

            try expectPath("lambda2", sub_section.path);
            try testing.expect(sub_section.inner_text != null);
            try testing.expectEqualStrings("{{x}}", sub_section.inner_text.?);
            try testing.expectEqual(@as(usize, 1), sub_section.children_count);

            try testing.expectEqual(Element.Type.interpolation, elements[3]);
            try expectPath("x", elements[3].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings(">", elements[4].static_text);
        }
    };

    const extra = struct {
        test "Basic DOM test" {
            const template_text =
                \\{{! Comments block }}
                \\  Hello
                \\  {{#section}}
                \\Name: {{name}}
                \\Comments: {{&comments}}
                \\{{^inverted}}Inverted text{{/inverted}}
                \\{{/section}}
                \\World
            ;

            var template = try getTemplate(template_text, .runtime_loaded);
            defer template.deinit();

            try testing.expect(template.result == .elements);
            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 11), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  Hello\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("section", elements[1].section.path);
            try testing.expectEqual(@as(usize, 8), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("Name: ", elements[2].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[3]);
            try expectPath("name", elements[3].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings("\nComments: ", elements[4].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[5]);
            try expectPath("comments", elements[5].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[7]);
            try expectPath("inverted", elements[7].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[7].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[8]);
            try testing.expectEqualStrings("Inverted text", elements[8].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[9]);
            try testing.expectEqualStrings("\n", elements[9].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[10]);
            try testing.expectEqualStrings("World", elements[10].static_text);
        }

        test "Basic DOM File test" {
            const template_text =
                \\{{! Comments block }}
                \\  Hello
                \\  {{#section}}
                \\Name: {{name}}
                \\Comments: {{&comments}}
                \\{{^inverted}}Inverted text{{/inverted}}
                \\{{/section}}
                \\World
            ;

            const allocator = testing.allocator;

            const path = try std.fs.selfExeDirPathAlloc(allocator);
            defer allocator.free(path);

            // Creating a temp file
            const absolute_file_path = try std.fs.path.join(allocator, &.{ path, "temp.mustache" });
            defer allocator.free(absolute_file_path);

            {
                var file = try std.fs.createFileAbsolute(absolute_file_path, .{ .truncate = true });
                try file.writeAll(template_text);
                defer file.close();
            }

            defer std.fs.deleteFileAbsolute(absolute_file_path) catch {};

            // Read from a file, assuring that this text should read four times from the buffer
            const read_buffer_size = (template_text.len / 4);
            const SmallBufferTemplateloader = TemplateLoader(.{
                .source = .{ .file = .{ .read_buffer_size = read_buffer_size } },
                .output = .cache,
            });

            var template = SmallBufferTemplateloader{
                .allocator = allocator,
            };

            defer template.deinit();

            try template.load(absolute_file_path);

            try testing.expect(template.result == .elements);
            const elements = template.result.elements;

            try testing.expectEqual(@as(usize, 11), elements.len);

            try testing.expectEqual(Element.Type.static_text, elements[0]);
            try testing.expectEqualStrings("  Hello\n", elements[0].static_text);

            try testing.expectEqual(Element.Type.section, elements[1]);
            try expectPath("section", elements[1].section.path);
            try testing.expectEqual(@as(usize, 8), elements[1].section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[2]);
            try testing.expectEqualStrings("Name: ", elements[2].static_text);

            try testing.expectEqual(Element.Type.interpolation, elements[3]);
            try expectPath("name", elements[3].interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[4]);
            try testing.expectEqualStrings("\nComments: ", elements[4].static_text);

            try testing.expectEqual(Element.Type.unescaped_interpolation, elements[5]);
            try expectPath("comments", elements[5].unescaped_interpolation);

            try testing.expectEqual(Element.Type.static_text, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].static_text);

            try testing.expectEqual(Element.Type.inverted_section, elements[7]);
            try expectPath("inverted", elements[7].inverted_section.path);
            try testing.expectEqual(@as(usize, 1), elements[7].inverted_section.children_count);

            try testing.expectEqual(Element.Type.static_text, elements[8]);
            try testing.expectEqualStrings("Inverted text", elements[8].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[9]);
            try testing.expectEqualStrings("\n", elements[9].static_text);

            try testing.expectEqual(Element.Type.static_text, elements[10]);
            try testing.expectEqualStrings("World", elements[10].static_text);
        }

        test "Large DOM File test" {
            const template_text =
                \\{{! Comments block }}
                \\  Hello
                \\  {{#section}}
                \\Name: {{name}}
                \\Comments: {{&comments}}
                \\{{^inverted}}Inverted text{{/inverted}}
                \\{{/section}}
                \\World
            ;

            const allocator = testing.allocator;

            const path = try std.fs.selfExeDirPathAlloc(allocator);
            defer allocator.free(path);

            // Creating a temp file
            const test_10MB_file = try std.fs.path.join(allocator, &.{ path, "10MB_file.mustache" });
            defer allocator.free(test_10MB_file);

            var file = try std.fs.createFileAbsolute(test_10MB_file, .{ .truncate = true });
            defer std.fs.deleteFileAbsolute(test_10MB_file) catch {};

            // Writes the same template many times on a file
            const REPEAT = 100_000;
            var step: usize = 0;
            while (step < REPEAT) : (step += 1) {
                try file.writeAll(template_text);
            }

            const file_size = try file.getEndPos();
            file.close();

            // Must be at least 10MB big
            try testing.expect(file_size > 10 * 1024 * 1024);

            // 32KB should be enough memory for this job
            // 16KB if we don't need to support lambdas 😅
            var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
                .requested_memory_limit = 32 * 1024,
            };
            defer _ = plenty_of_memory.deinit();

            // Strings are not ownned by the template,
            // Use this option when creating templates from a static string or when rendering direct to a stream
            const RefStringsTemplate = TemplateLoader(.{
                .source = .{ .file = .{} },
                .output = .render,
            });

            // Create a template to parse and render this 10MB file, with only 16KB of memory
            var template = RefStringsTemplate{
                .allocator = plenty_of_memory.allocator(),
            };

            defer template.deinit();

            // A dummy render, just count the produced elements
            const DummyRender = struct {
                pub const Error = error{};

                count: usize = 0,

                pub fn render(ctx: *@This(), elements: []Element) Error!void {
                    ctx.count += elements.len;
                    checkStrings(elements);
                }

                // Check if all strings are valid
                // As long we are running with own_string = false,
                // Those strings must be valid during the render process
                fn checkStrings(elements: []const Element) void {
                    for (elements) |element| {
                        switch (element) {
                            .static_text => |item| scan(item),
                            .interpolation => |item| scanPath(item),
                            .unescaped_interpolation => |item| scanPath(item),
                            .section => |item| scanPath(item.path),
                            .inverted_section => |item| scanPath(item.path),
                            .partial => |item| scan(item.key),
                            .parent => |item| scan(item.key),
                            .block => |item| scan(item.key),
                        }
                    }
                }

                // Just scans the whole slice, hopping for no segfault
                fn scan(string: []const u8) void {
                    var prev_char: u8 = 0;
                    for (string) |char| {
                        prev_char = prev_char +% char;
                    }
                    _ = prev_char;
                }

                fn scanPath(value: Element.Path) void {
                    for (value) |part| scan(part);
                }
            };

            var dummy_render = DummyRender{};
            try template.collectElements(test_10MB_file, &dummy_render);

            try testing.expectEqual(@as(usize, 11 * REPEAT), dummy_render.count);
        }
    };

    const api = struct {
        test "parseText API" {
            var result = result: {
                var template_text = try testing.allocator.dupe(u8, "{{hello}}world");
                defer testing.allocator.free(template_text);

                break :result try parseText(testing.allocator, template_text, .{}, .{ .copy_strings = true });
            };

            switch (result) {
                .parse_error => {
                    try testing.expect(false);
                },
                .success => |template| {
                    defer template.deinit(testing.allocator);
                    try testing.expectEqual(@as(usize, 2), template.elements.len);
                    try testing.expectEqual(Element.Type.interpolation, template.elements[0]);
                    try testing.expectEqual(Element.Type.static_text, template.elements[1]);
                    try testing.expectEqualStrings("hello", template.elements[0].interpolation[0]);
                    try testing.expectEqualStrings("world", template.elements[1].static_text);
                },
            }
        }

        test "parseComptime API" {
            const template = mustache.parseComptime("{{hello}}world", .{}, .{});
            try testing.expectEqual(@as(usize, 2), template.elements.len);
            try testing.expectEqual(Element.Type.interpolation, template.elements[0]);
            try testing.expectEqual(Element.Type.static_text, template.elements[1]);
            try testing.expectEqualStrings("hello", template.elements[0].interpolation[0]);
            try testing.expectEqualStrings("world", template.elements[1].static_text);
        }

        test "parseFile API" {
            var result = result: {
                var tmp = testing.tmpDir(.{});
                defer tmp.cleanup();

                var file_name = file_name: {
                    const name = "parseFile.mustache";

                    {
                        var file = try tmp.dir.createFile(name, .{ .truncate = true });
                        defer file.close();

                        try file.writeAll("{{hello}}world");
                    }

                    break :file_name try tmp.dir.realpathAlloc(testing.allocator, name);
                };
                defer testing.allocator.free(file_name);
                break :result try parseFile(testing.allocator, file_name, .{}, .{});
            };

            switch (result) {
                .parse_error => {
                    try testing.expect(false);
                },
                .success => |template| {
                    defer template.deinit(testing.allocator);
                    try testing.expectEqual(@as(usize, 2), template.elements.len);
                    try testing.expectEqual(Element.Type.interpolation, template.elements[0]);
                    try testing.expectEqual(Element.Type.static_text, template.elements[1]);
                    try testing.expectEqualStrings("hello", template.elements[0].interpolation[0]);
                    try testing.expectEqualStrings("world", template.elements[1].static_text);
                },
            }
        }
    };
};
