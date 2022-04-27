const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;
const TemplateSource = mustache.options.TemplateSource;
const Features = mustache.options.Features;

const parsing = @import("parsing/parsing.zig");
const Node = parsing.Node;

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
    ParseError: ParseErrorDetail,
    Success: Template,
};

pub const Element = union(Element.Type) {
    StaticText: []const u8,
    Interpolation: Path,
    UnescapedInterpolation: Path,
    Section: Section,
    InvertedSection: InvertedSection,
    Partial: Partial,
    Parent: Parent,
    Block: Block,

    pub const Path = []const []const u8;

    pub const Type = enum {

        /// Static text
        StaticText,

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
        Interpolation,
        UnescapedInterpolation,

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
        Section,
        InvertedSection,

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
        Partial,

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
        Parent,

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
        Block,
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
            .StaticText => |content| if (owns_string) allocator.free(content),
            .Interpolation => |path| destroyPath(allocator, owns_string, path),
            .UnescapedInterpolation => |path| destroyPath(allocator, owns_string, path),
            .Section => |section| {
                destroyPath(allocator, owns_string, section.path);
                if (owns_string) {
                    if (section.inner_text) |inner_text| allocator.free(inner_text);
                }
            },
            .InvertedSection => |section| {
                destroyPath(allocator, owns_string, section.path);
            },
            .Partial => |partial| {
                if (owns_string) {
                    allocator.free(partial.key);
                    if (partial.indentation) |indentation| allocator.free(indentation);
                }
            },

            .Parent => |parent| {
                if (owns_string) allocator.free(parent.key);
            },

            .Block => |block| {
                if (owns_string) allocator.free(block.key);
            },
        }
    }

    pub fn deinitMany(allocator: Allocator, owns_string: bool, items: []const Element) void {
        for (items) |item| {
            item.deinit(allocator, owns_string);
        }
        allocator.free(items);
    }

    pub fn createPath(allocator: Allocator, copy_strings: bool, identifier: []const u8) Allocator.Error!Path {
        const action = struct {
            pub fn action(_allocator: Allocator, _copy_strings: bool, iterator: *std.mem.TokenIterator(u8), index: usize) Allocator.Error!?[][]const u8 {
                if (iterator.next()) |part| {
                    var path = (try action(_allocator, _copy_strings, iterator, index + 1)) orelse unreachable;
                    path[index] = if (_copy_strings) try _allocator.dupe(u8, part) else part;
                    return path;
                } else {
                    return if (index == 0)
                        null
                    else
                        try _allocator.alloc([]const u8, index);
                }
            }
        }.action;

        const EMPTY: Path = &[0][]const u8{};

        if (identifier.len == 0) {
            return EMPTY;
        } else {
            const PATH_SEPARATOR = ".";
            var iterator = std.mem.tokenize(u8, identifier, PATH_SEPARATOR);
            return (try action(allocator, copy_strings, &iterator, 0)) orelse EMPTY;
        }
    }

    pub inline fn destroyPath(allocator: Allocator, owns_string: bool, path: Path) void {
        if (path.len > 0) {
            if (owns_string)
                for (path) |part| allocator.free(part);
            allocator.free(path);
        }
    }
};

pub const Template = struct {
    elements: []const Element,
    options: *const TemplateOptions,

    pub fn deinit(self: Template, allocator: Allocator) void {
        Element.deinitMany(allocator, self.options.copyStrings(), self.elements);
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

    //Note: the "default_delimiters" parameter must be runtime-known
    //This field could be inserted on "ParseTextOptions" when comptime fields get fixed
    //https://github.com/ziglang/zig/issues/5497

    const source = TemplateSource{ .String = .{ .copy_strings = options.copy_strings } };
    return try parseSource(source, options.features, allocator, template_text, default_delimiters);
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

    //Note: the "default_delimiters" parameter must be runtime-known
    //This field could be inserted on "ParseTextOptions" when comptime fields get fixed
    //https://github.com/ziglang/zig/issues/5497

    const source = TemplateSource{ .Stream = .{ .read_buffer_size = options.read_buffer_size } };
    return try parseSource(source, options.features, allocator, template_absolute_path, default_delimiters);
}

fn parseSource(
    comptime source: TemplateSource,
    comptime features: Features,
    allocator: Allocator,
    source_content: []const u8,
    delimiters: Delimiters,
) !ParseResult {
    const options = TemplateOptions{
        .source = source,
        .output = .Parse,
        .features = features,
    };

    var template = TemplateLoader(options){
        .allocator = allocator,
        .delimiters = delimiters,
    };

    errdefer template.deinit();

    switch (source) {
        .Stream => try template.loadFile(source_content),
        .String => try template.load(source_content),
    }

    switch (template.result) {
        .Error => |last_error| return ParseResult{ .ParseError = last_error },
        .Elements => |elements| return ParseResult{ .Success = .{ .elements = elements, .options = &options } },
        .NotLoaded => unreachable,
    }
}

pub fn TemplateLoader(comptime options: TemplateOptions) type {
    return struct {
        const Self = @This();

        const Parser = parsing.Parser(options);

        const Collector = struct {
            pub const Error = Allocator.Error;

            elements: []Element = undefined,

            pub fn render(ctx: *@This(), elements: []Element) Allocator.Error!void {
                ctx.elements = elements;
            }
        };

        allocator: Allocator,
        delimiters: Delimiters = .{},
        result: union(enum) {
            Elements: []const Element,
            Error: ParseErrorDetail,
            NotLoaded,
        } = .NotLoaded,

        pub fn load(self: *Self, template_text: []const u8) Parser.LoadError!void {
            var parser = try Parser.init(self.allocator, template_text, self.delimiters);
            defer parser.deinit();

            var collector = Collector{};
            try self.produceElements(&parser, &collector);

            if (self.result != .Error) {
                self.result = .{
                    .Elements = collector.elements,
                };
            }
        }

        pub fn loadFile(self: *Self, absolute_path: []const u8) Parser.LoadError!void {
            var parser = try Parser.init(self.allocator, absolute_path, self.delimiters);
            defer parser.deinit();

            var collector = Collector{};
            try self.produceElements(&parser, &collector);

            self.result = .{
                .Elements = collector.elements,
            };
        }

        pub fn collectElements(self: *Self, template_text: []const u8, render: anytype) ErrorSet(Parser, @TypeOf(render))!void {
            var parser = try Parser.init(self.allocator, template_text, self.delimiters);
            defer parser.deinit();

            try self.produceElements(&parser, render);
        }

        pub fn collectElementsFromFile(self: *Self, absolute_path: []const u8, render: anytype) ErrorSet(Parser, @TypeOf(render))!void {
            var parser = try Parser.init(self.allocator, absolute_path, self.delimiters);
            defer parser.deinit();

            try self.produceElements(&parser, render);
        }

        fn produceElements(
            self: *Self,
            parser: *Parser,
            render: anytype,
        ) ErrorSet(Parser, @TypeOf(render))!void {
            while (true) {
                var list = std.ArrayListUnmanaged(Element){};
                defer {
                    if (list.items.len > 0) {

                        // If a parser or render error occurs,
                        // some elements may be left unconsumed, and need to be freed
                        const non_consumed_elements = list.toOwnedSlice(self.allocator);
                        Element.deinitMany(self.allocator, options.copyStrings(), non_consumed_elements);
                    }

                    list.deinit(self.allocator);
                }

                var parse_result = try parser.parse();
                defer parser.ref_counter_holder.free(self.allocator);

                switch (parse_result) {
                    .Error => |err| {
                        self.result = .{
                            .Error = err,
                        };
                        return;
                    },
                    .Node => |node| {
                        var siblings = node.siblings();
                        _ = parser.createElements(&list, null, &siblings) catch |err| switch (err) {
                            error.ParserAbortedError => {

                                // TODO: implement a renderError function to render the error message on the output writer
                                assert(parser.last_error != null);
                                self.result = .{
                                    .Error = parser.last_error.?,
                                };
                                return;
                            },
                            else => return @errSetCast(ErrorSet(@TypeOf(parser), @TypeOf(render)), err),
                        };

                        const elements = list.toOwnedSlice(self.allocator);
                        defer if (options.output == .Render) Element.deinitMany(self.allocator, options.copyStrings(), elements);
                        try render.render(elements);

                        // No need for loop again
                        // when output == .Parse, all nodes are produced at once
                        if (options.output == .Parse) break;
                    },
                    .Done => break,
                }
            }
        }

        pub fn deinit(self: *Self) void {
            switch (self.result) {
                .Elements => |elements| Element.deinitMany(self.allocator, options.copyStrings(), elements),
                .Error, .NotLoaded => {},
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

    const options = TemplateOptions{
        .source = .{ .String = .{} },
        .output = .Parse,
    };

    pub fn getTemplate(template_text: []const u8) !TemplateLoader(options) {
        const allocator = testing.allocator;

        var template = TemplateLoader(options){
            .allocator = allocator,
        };
        errdefer template.deinit();

        try template.load(template_text);

        if (template.result == .Error) {
            const detail = template.result.Error;
            std.log.err("{s} row {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            return detail.parse_error;
        }

        return template;
    }

    pub fn expectPath(expected: []const u8, path: Element.Path) !void {
        const allocator = testing.allocator;
        const expected_path = try Element.createPath(allocator, false, expected);
        defer Element.destroyPath(allocator, false, expected_path);

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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("12345", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("67890", elements[1].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("12345", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("67890", elements[1].StaticText);
        }

        //
        // All standalone comment lines should be removed.
        test "Standalone" {
            const template_text =
                \\Begin.
                \\{{! Comment Block! }}
                \\End.
            ;

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
        }

        //
        // All standalone comment lines should be removed.
        test "Indented Standalone" {
            const template_text =
                \\Begin.
                \\    {{! Indented Comment Block! }}
                \\End.
            ;

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
        }

        //
        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{! Standalone Comment }}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);

            try testing.expectEqualStrings("|", elements[1].StaticText);
        }

        //
        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "!\n  {{! I'm Still Standalone }}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("!\n", elements[0].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
        }

        //
        // Inline comments should not strip whitespace.
        test "Indented Inline" {
            const template_text = "  12 {{! 34 }}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  12 ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("\n", elements[1].StaticText);
        }

        //
        // Comment removal should preserve surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "12345 {{! Comment Block! }} 67890";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("12345 ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings(" 67890", elements[1].StaticText);
        }
    };

    const delimiters = struct {

        //
        // The equals sign (used on both sides) should permit delimiter changes.
        test "Pair Behavior" {
            const template_text = "{{=<% %>=}}(<%text%>)";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("(", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("text", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(")", elements[2].StaticText);
        }

        //
        // Characters with special meaning regexen should be valid delimiters.
        test "Special Characters" {
            const template_text = "({{=[ ]=}}[text])";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("(", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("text", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(")", elements[2].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 10), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("section", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 3), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[3]);
            try expectPath("data", elements[3].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings("\n  |data|\n", elements[4].StaticText);

            // Delimiters changed

            try testing.expectEqual(Element.Type.Section, elements[5]);
            try expectPath("section", elements[5].Section.path);
            try testing.expectEqual(@as(usize, 3), elements[5].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("  {{data}}\n  ", elements[6].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[7]);
            try expectPath("data", elements[7].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[8]);
            try testing.expectEqualStrings("\n", elements[8].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[9]);
            try testing.expectEqualStrings("]", elements[9].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 10), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("section", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 3), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[3]);
            try expectPath("data", elements[3].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings("\n  |data|\n", elements[4].StaticText);

            // Delimiters changed

            try testing.expectEqual(Element.Type.InvertedSection, elements[5]);
            try expectPath("section", elements[5].InvertedSection.path);
            try testing.expectEqual(@as(usize, 3), elements[5].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("  {{data}}\n  ", elements[6].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[7]);
            try expectPath("data", elements[7].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[8]);
            try testing.expectEqualStrings("\n", elements[8].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[9]);
            try testing.expectEqualStrings("]", elements[9].StaticText);
        }

        //
        // Surrounding whitespace should be left untouched.
        test "Surrounding Whitespace" {
            const template_text = "| {{=@ @=}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings(" |", elements[1].StaticText);
        }

        //
        // Whitespace should be left untouched.
        test "Outlying Whitespace (Inline)" {
            const template_text = " | {{=@ @=}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("\n", elements[1].StaticText);
        }

        //
        // Standalone lines should be removed from the template.
        test "Standalone Tag" {
            const template_text =
                \\Begin.
                \\{{=@ @=}}
                \\End.
            ;

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
        }

        //
        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Tag" {
            const template_text =
                \\Begin.
                \\{{=@ @=}}
                \\End.
            ;

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("End.", elements[1].StaticText);
        }

        //
        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{= @ @ =}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("|", elements[1].StaticText);
        }

        //
        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{=@ @=}}\n=";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("=", elements[0].StaticText);
        }

        //
        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "=\n  {{=@ @=}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("=\n", elements[0].StaticText);
        }

        //
        // Superfluous in-tag whitespace should be ignored.
        test "Pair with Padding" {
            const template_text = "|{{= @   @ =}}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("|", elements[1].StaticText);
        }
    };

    const interpolation = struct {

        // Mustache-free templates should render as-is.
        test "No Interpolation" {
            const template_text = "Hello from {Mustache}!";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 1), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Hello from {Mustache}!", elements[0].StaticText);
        }

        // Unadorned tags should interpolate content into the template.
        test "Basic Interpolation" {
            const template_text = "Hello, {{subject}}!";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("Hello, ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("subject", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("!", elements[2].StaticText);
        }

        // Basic interpolation should be HTML escaped.
        test "HTML Escaping" {
            const template_text = "These characters should be HTML escaped: {{forbidden}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("forbidden", elements[1].Interpolation);
        }

        // Triple mustaches should interpolate without HTML escaping.
        test "Triple Mustache" {
            const template_text = "These characters should not be HTML escaped: {{{forbidden}}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("forbidden", elements[1].UnescapedInterpolation);
        }

        // Ampersand should interpolate without HTML escaping.
        test "Ampersand" {
            const template_text = "These characters should not be HTML escaped: {{&forbidden}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("forbidden", elements[1].UnescapedInterpolation);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Interpolation - Surrounding Whitespace" {
            const template_text = "| {{string}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("string", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Surrounding Whitespace" {
            const template_text = "| {{{string}}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Ampersand - Surrounding Whitespace" {
            const template_text = "| {{&string}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Interpolation - Standalone" {
            const template_text = "  {{string}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("string", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Standalone" {
            const template_text = "  {{{string}}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Ampersand - Standalone" {
            const template_text = "  {{&string}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Interpolation With Padding" {
            const template_text = "|{{ string }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("string", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Triple Mustache With Padding" {
            const template_text = "|{{{ string }}}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Ampersand With Padding" {
            const template_text = "|{{& string }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[1]);
            try expectPath("string", elements[1].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }
    };

    const sections = struct {

        // Sections should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = " | {{#boolean}}\t|\t{{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\t|\t", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings(" | \n", elements[3].StaticText);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{#boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 2), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings(" | \n", elements[4].StaticText);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{#boolean}}YES{{/boolean}}\n {{#boolean}}GOOD{{/boolean}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 7), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("YES", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[4]);
            try expectPath("boolean", elements[4].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[4].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[5]);
            try testing.expectEqualStrings("GOOD", elements[5].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].StaticText);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{#boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 0), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{#boolean}}\n#{{/boolean}}\n/";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.Section, elements[0]);
            try expectPath("boolean", elements[0].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[0].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("#", elements[1].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n/", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "#{{#boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("#", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n/\n", elements[2].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{# boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("boolean", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("=", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("|", elements[3].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 77), elements.len);

            try testing.expectEqual(Element.Type.Section, elements[0]);
            try expectPath("a", elements[0].Section.path);

            {
                try testing.expectEqual(@as(usize, 76), elements[0].Section.children_count);

                try testing.expectEqual(Element.Type.Interpolation, elements[1]);
                try expectPath("one", elements[1].Interpolation);

                try testing.expectEqual(Element.Type.StaticText, elements[2]);
                try testing.expectEqualStrings("\n", elements[2].StaticText);

                try testing.expectEqual(Element.Type.Section, elements[3]);
                try expectPath("b", elements[3].Section.path);

                {
                    try testing.expectEqual(@as(usize, 71), elements[3].Section.children_count);

                    try testing.expectEqual(Element.Type.Interpolation, elements[4]);
                    try expectPath("one", elements[4].Interpolation);

                    try testing.expectEqual(Element.Type.Interpolation, elements[5]);
                    try expectPath("two", elements[5].Interpolation);

                    try testing.expectEqual(Element.Type.Interpolation, elements[6]);
                    try expectPath("one", elements[6].Interpolation);

                    try testing.expectEqual(Element.Type.StaticText, elements[7]);
                    try testing.expectEqualStrings("\n", elements[7].StaticText);

                    try testing.expectEqual(Element.Type.Section, elements[8]);
                    try expectPath("c", elements[8].Section.path);

                    {
                        try testing.expectEqual(@as(usize, 62), elements[8].Section.children_count);
                        // Too lazy to do the rest ... 🙃
                    }

                    try testing.expectEqual(Element.Type.Interpolation, elements[71]);
                    try expectPath("one", elements[71].Interpolation);

                    try testing.expectEqual(Element.Type.Interpolation, elements[72]);
                    try expectPath("two", elements[72].Interpolation);

                    try testing.expectEqual(Element.Type.Interpolation, elements[73]);
                    try expectPath("one", elements[73].Interpolation);

                    try testing.expectEqual(Element.Type.StaticText, elements[74]);
                    try testing.expectEqualStrings("\n", elements[74].StaticText);
                }

                try testing.expectEqual(Element.Type.Interpolation, elements[75]);
                try expectPath("one", elements[75].Interpolation);

                try testing.expectEqual(Element.Type.StaticText, elements[76]);
                try testing.expectEqualStrings("\n", elements[76].StaticText);
            }
        }
    };

    const inverted = struct {

        // Sections should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = " | {{^boolean}}\t|\t{{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\t|\t", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings(" | \n", elements[3].StaticText);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{^boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 2), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings(" | \n", elements[4].StaticText);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{^boolean}}NO{{/boolean}}\n {{^boolean}}WAY{{/boolean}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 7), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("NO", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("\n ", elements[3].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[4]);
            try expectPath("boolean", elements[4].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[4].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[5]);
            try testing.expectEqualStrings("WAY", elements[5].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].StaticText);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{^boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 0), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{^boolean}}\n^{{/boolean}}\n/";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.InvertedSection, elements[0]);
            try expectPath("boolean", elements[0].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[0].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings("^", elements[1].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n/", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "^{{^boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("^", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("\n/\n", elements[2].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|\n", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("| A Line", elements[3].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{^ boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[1]);
            try expectPath("boolean", elements[1].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[1].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("=", elements[2].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings("|", elements[3].StaticText);
        }
    };

    const partials_section = struct {

        // The greater-than operator should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "| {{>partial}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation == null);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Whitespace should be left untouched.
        test "Inline Indentation" {
            const template_text = "  {{data}}  {{> partial}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[1]);
            try expectPath("data", elements[1].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[3]);
            try testing.expectEqualStrings("partial", elements[3].Partial.key);
            try testing.expect(elements[3].Partial.indentation == null);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings("\n", elements[4].StaticText);
        }

        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{>partial}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation == null);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{>partial}}\n>";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.Partial, elements[0]);
            try testing.expectEqualStrings("partial", elements[0].Partial.key);
            try testing.expect(elements[0].Partial.indentation != null);
            try testing.expectEqualStrings("  ", elements[0].Partial.indentation.?);

            try testing.expectEqual(Element.Type.StaticText, elements[1]);
            try testing.expectEqualStrings(">", elements[1].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = ">\n  {{>partial}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings(">\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation != null);
            try testing.expectEqualStrings("  ", elements[1].Partial.indentation.?);
        }

        // Each line of the partial should be indented before rendering.
        test "Standalone Indentation" {
            const template_text =
                \\  \
                \\   {{>partial}}
                \\  /
            ;

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  \\\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation != null);
            try testing.expectEqualStrings("   ", elements[1].Partial.indentation.?);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("  /", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{> partial }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }
    };

    const lambdas = struct {

        // Lambdas used for sections should receive the raw section string.
        test "Sections" {
            const template_text = "<{{#lambda}}{{x}}{{/lambda}}>";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("<", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("lambda", elements[1].Section.path);
            try testing.expect(elements[1].Section.inner_text != null);
            try testing.expectEqualStrings("{{x}}", elements[1].Section.inner_text.?);
            try testing.expectEqual(@as(usize, 1), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.Interpolation, elements[2]);
            try expectPath("x", elements[2].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[3]);
            try testing.expectEqualStrings(">", elements[3].StaticText);
        }

        // Lambdas used for sections should receive the raw section string.
        test "Nested Sections" {
            const template_text = "<{{#lambda}}{{#lambda2}}{{x}}{{/lambda2}}{{/lambda}}>";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("<", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);

            const section = elements[1].Section;
            try expectPath("lambda", section.path);
            try testing.expect(section.inner_text != null);
            try testing.expectEqualStrings("{{#lambda2}}{{x}}{{/lambda2}}", section.inner_text.?);
            try testing.expectEqual(@as(usize, 2), section.children_count);

            try testing.expectEqual(Element.Type.Section, elements[2]);
            const sub_section = elements[2].Section;

            try expectPath("lambda2", sub_section.path);
            try testing.expect(sub_section.inner_text != null);
            try testing.expectEqualStrings("{{x}}", sub_section.inner_text.?);
            try testing.expectEqual(@as(usize, 1), sub_section.children_count);

            try testing.expectEqual(Element.Type.Interpolation, elements[3]);
            try expectPath("x", elements[3].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings(">", elements[4].StaticText);
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

            var template = try getTemplate(template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 11), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  Hello\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("section", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 8), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("Name: ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[3]);
            try expectPath("name", elements[3].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings("\nComments: ", elements[4].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[5]);
            try expectPath("comments", elements[5].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[7]);
            try expectPath("inverted", elements[7].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[7].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[8]);
            try testing.expectEqualStrings("Inverted text", elements[8].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[9]);
            try testing.expectEqualStrings("\n", elements[9].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[10]);
            try testing.expectEqualStrings("World", elements[10].StaticText);
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

            var file = try std.fs.createFileAbsolute(absolute_file_path, .{ .truncate = true });
            try file.writeAll(template_text);
            file.close();
            defer std.fs.deleteFileAbsolute(absolute_file_path) catch {};

            // Read from a file, assuring that this text should read four times from the buffer
            const read_buffer_size = (template_text.len / 4);
            const SmallBufferTemplateloader = TemplateLoader(.{
                .source = .{ .Stream = .{ .read_buffer_size = read_buffer_size } },
                .output = .Parse,
            });

            var template = SmallBufferTemplateloader{
                .allocator = allocator,
            };

            defer template.deinit();

            try template.loadFile(absolute_file_path);

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 11), elements.len);

            try testing.expectEqual(Element.Type.StaticText, elements[0]);
            try testing.expectEqualStrings("  Hello\n", elements[0].StaticText);

            try testing.expectEqual(Element.Type.Section, elements[1]);
            try expectPath("section", elements[1].Section.path);
            try testing.expectEqual(@as(usize, 8), elements[1].Section.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[2]);
            try testing.expectEqualStrings("Name: ", elements[2].StaticText);

            try testing.expectEqual(Element.Type.Interpolation, elements[3]);
            try expectPath("name", elements[3].Interpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[4]);
            try testing.expectEqualStrings("\nComments: ", elements[4].StaticText);

            try testing.expectEqual(Element.Type.UnescapedInterpolation, elements[5]);
            try expectPath("comments", elements[5].UnescapedInterpolation);

            try testing.expectEqual(Element.Type.StaticText, elements[6]);
            try testing.expectEqualStrings("\n", elements[6].StaticText);

            try testing.expectEqual(Element.Type.InvertedSection, elements[7]);
            try expectPath("inverted", elements[7].InvertedSection.path);
            try testing.expectEqual(@as(usize, 1), elements[7].InvertedSection.children_count);

            try testing.expectEqual(Element.Type.StaticText, elements[8]);
            try testing.expectEqualStrings("Inverted text", elements[8].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[9]);
            try testing.expectEqualStrings("\n", elements[9].StaticText);

            try testing.expectEqual(Element.Type.StaticText, elements[10]);
            try testing.expectEqualStrings("World", elements[10].StaticText);
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

            const size = try file.getEndPos();
            file.close();

            // Must be at least 10MB big
            try testing.expect(size > 10 * 1024 * 1024);

            // 32KB should be enough memory for this job
            // 16KB if we don't need to support lambdas 😅
            var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
                .requested_memory_limit = 32 * 1024,
            };
            defer _ = plenty_of_memory.deinit();

            // Strings are not ownned by the template,
            // Use this option when creating templates from a static string or when rendering direct to a stream
            const RefStringsTemplate = TemplateLoader(.{
                .source = .{ .Stream = .{} },
                .output = .Render,
            });

            // Create a template to parse and render this 10MB file, with only 16KB of memory
            var template = RefStringsTemplate{
                .allocator = plenty_of_memory.allocator(),
            };

            defer template.deinit();

            // A dummy render, just count the produced elements
            const DummyRender = struct {
                pub const Error = Allocator.Error;

                count: usize = 0,

                pub fn render(self: *@This(), elements: []Element) Allocator.Error!void {
                    self.count += elements.len;
                    checkStrings(elements);
                }

                // Check if all strings are valid
                // As long we are running with own_string = false,
                // Those strings must be valid during the render process
                fn checkStrings(elements: []const Element) void {
                    for (elements) |element| {
                        switch (element) {
                            .StaticText => |item| scan(item),
                            .Interpolation => |item| scanPath(item),
                            .UnescapedInterpolation => |item| scanPath(item),
                            .Section => |item| scanPath(item.path),
                            .InvertedSection => |item| scanPath(item.path),
                            .Partial => |item| scan(item.key),
                            .Parent => |item| scan(item.key),
                            .Block => |item| scan(item.key),
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
            try template.collectElementsFromFile(test_10MB_file, &dummy_render);

            try testing.expectEqual(@as(usize, 11 * REPEAT), dummy_render.count);
        }
    };

    const api = struct {
        test "Path" {
            const allocator = testing.allocator;

            {
                var empty_1 = try Element.createPath(allocator, false, "");
                defer Element.destroyPath(allocator, false, empty_1);

                try testing.expectEqual(@as(usize, 0), empty_1.len);
            }

            {
                var empty_2 = try Element.createPath(allocator, false, ".");
                defer Element.destroyPath(allocator, false, empty_2);

                try testing.expectEqual(@as(usize, 0), empty_2.len);
            }

            {
                var empty_3 = try Element.createPath(allocator, false, "..");
                defer Element.destroyPath(allocator, false, empty_3);

                try testing.expectEqual(@as(usize, 0), empty_3.len);
            }

            {
                var single1 = try Element.createPath(allocator, false, "a");
                defer Element.destroyPath(allocator, false, single1);

                try testing.expectEqual(@as(usize, 1), single1.len);
                try testing.expectEqualStrings("a", single1[0]);
            }

            {
                var single2 = try Element.createPath(allocator, false, ".a");
                defer Element.destroyPath(allocator, false, single2);

                try testing.expectEqual(@as(usize, 1), single2.len);
                try testing.expectEqualStrings("a", single2[0]);
            }

            {
                var single3 = try Element.createPath(allocator, false, ".a.");
                defer Element.destroyPath(allocator, false, single3);

                try testing.expectEqual(@as(usize, 1), single3.len);
                try testing.expectEqualStrings("a", single3[0]);
            }

            {
                var double1 = try Element.createPath(allocator, false, "a.b");
                defer Element.destroyPath(allocator, false, double1);

                try testing.expectEqual(@as(usize, 2), double1.len);
                try testing.expectEqualStrings("a", double1[0]);
                try testing.expectEqualStrings("b", double1[1]);
            }

            {
                var double2 = try Element.createPath(allocator, false, ".a.b");
                defer Element.destroyPath(allocator, false, double2);

                try testing.expectEqual(@as(usize, 2), double2.len);
                try testing.expectEqualStrings("a", double2[0]);
                try testing.expectEqualStrings("b", double2[1]);
            }

            {
                var double3 = try Element.createPath(allocator, false, ".a.b.");
                defer Element.destroyPath(allocator, false, double3);

                try testing.expectEqual(@as(usize, 2), double3.len);
                try testing.expectEqualStrings("a", double3[0]);
                try testing.expectEqualStrings("b", double3[1]);
            }
        }

        test "parseText API" {
            var result = try parseText(testing.allocator, "{{hello}}world", .{}, .{ .copy_strings = true });
            switch (result) {
                .ParseError => {
                    try testing.expect(false);
                },
                .Success => |template| {
                    template.deinit(testing.allocator);
                },
            }
        }

        test "parseFile API" {
            var file_name = file_name: {
                var tmp = testing.tmpDir(.{});
                var file = try tmp.dir.createFile("parseFile.mustache", .{ .truncate = true });
                defer file.close();

                try file.writeAll("{{hello}}world");

                break :file_name try tmp.dir.realpathAlloc(testing.allocator, "parseFile.mustache");
            };
            defer testing.allocator.free(file_name);

            var result = try parseFile(testing.allocator, file_name, .{}, .{});
            switch (result) {
                .ParseError => {
                    try testing.expect(false);
                },
                .Success => |template| {
                    template.deinit(testing.allocator);
                },
            }
        }
    };
};
