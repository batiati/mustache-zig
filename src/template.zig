const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const parsing = @import("parsing/parsing.zig");
const Parser = parsing.Parser;
const Node = parsing.Node;

pub const Delimiters = parsing.Delimiters;

pub const ParseErrors = error{
    StartingDelimiterMismatch,
    EndingDelimiterMismatch,
    UnexpectedEof,
    UnexpectedCloseSection,
    InvalidDelimiters,
    InvalidIdentifier,
    ClosingTagMismatch,
};

pub const LastError = struct {
    error_code: anyerror,
    row: usize = 0,
    col: usize = 0,
    detail: ?[]const u8 = null,
};

pub const Interpolation = struct {
    escaped: bool,
    key: []const u8,
};

pub const Section = struct {
    inverted: bool,
    key: []const u8,
    content: ?[]const Element,
};

pub const Partial = struct {
    key: []const u8,
    indentation: ?[]const u8,
};

pub const Parent = struct {
    key: []const u8,
    indentation: ?[]const u8,
    content: ?[]const Element,
};

pub const Block = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Element = union(enum) {

    /// Static text
    StaticText: []const u8,

    ///
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
    Interpolation: Interpolation,

    ///
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
    Section: Section,

    ///
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
    Partial: Partial,

    ///
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
    Parent: Parent,

    ///
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
    Block: Block,

    pub fn free(self: Element, allocator: Allocator, own_strings: bool) void {
        switch (self) {
            .StaticText => |content| if (own_strings) allocator.free(content),
            .Interpolation => |interpolation| if (own_strings) allocator.free(interpolation.key),
            .Section => |section| {
                if (own_strings) allocator.free(section.key);
                freeMany(allocator, own_strings, section.content);
            },

            .Partial => |partial| {
                if (own_strings) allocator.free(partial.key);
                if (partial.indentation) |indentation| allocator.free(indentation);
            },

            .Parent => |inheritance| {
                if (own_strings) allocator.free(inheritance.key);
                freeMany(allocator, own_strings, inheritance.content);
            },

            .Block => |block| {
                if (own_strings) allocator.free(block.key);
                freeMany(allocator, own_strings, block.content);
            },
        }
    }

    pub fn freeMany(allocator: Allocator, own_strings: bool, many: ?[]const Element) void {
        if (many) |items| {
            for (items) |item| {
                item.free(allocator, own_strings);
            }
            allocator.free(items);
        }
    }
};

pub const TemplateOptions = struct {
    delimiters: Delimiters = .{},
    read_buffer_size: usize = 4 * 1024,
    own_strings: bool = true,
};

pub const Template = struct {
    const Self = @This();

    allocator: Allocator,
    options: TemplateOptions,
    result: union(enum) {
        Elements: []const Element,
        Error: LastError,
        NotLoaded,
    } = .NotLoaded,

    pub fn init(allocator: Allocator, template_text: []const u8, options: TemplateOptions) !Template {
        var self = Self{
            .allocator = allocator,
            .options = options,
        };

        try self.load(template_text);
        return self;
    }

    pub fn initFromFile(allocator: Allocator, absolute_path: []const u8, options: TemplateOptions) !Template {
        var self = Self{
            .allocator = allocator,
            .options = options,
        };

        try self.loadFromFile(absolute_path);
        return self;
    }

    fn load(self: *Self, template_text: []const u8) !void {
        var parser = try Parser.init(self.allocator, template_text, self.options);
        defer parser.deinit();

        try self.parse(&parser);
    }

    fn loadFromFile(self: *Self, absolute_path: []const u8) !void {
        var parser = try Parser.initFromFile(self.allocator, absolute_path, self.options);
        defer parser.deinit();

        try self.parse(&parser);
    }

    fn renderFromFile(self: *Self, absolute_path: []const u8, render: anytype, action: fn (ctx: @TypeOf(render), template: *Self, elements: []Element) anyerror!void) !void {
        var parser = try Parser.initFromFile(self.allocator, absolute_path, self.options);
        defer parser.deinit();
        try self.parseStream(&parser, render, action);
    }

    fn parse(self: *Self, parser: *Parser) !void {
        const Closure = struct {
            list: std.ArrayListUnmanaged(Element) = .{},

            pub fn action(ctx: *@This(), outer: *Self, elements: []Element) anyerror!void {
                try ctx.list.appendSlice(outer.allocator, elements);
                outer.allocator.free(elements);
            }
        };

        var closure = Closure{};
        errdefer closure.list.deinit(self.allocator);

        try self.parseStream(parser, &closure, Closure.action);

        self.result = .{
            .Elements = closure.list.toOwnedSlice(self.allocator),
        };
    }

    fn parseStream(self: *Self, parser: *Parser, context: anytype, action: fn (ctx: @TypeOf(context), self: *Self, elements: []Element) anyerror!void) !void {
        while (true) {
            var parse_result = try parser.parse();

            // When "options.own_strings = false", all read buffer must be freed after producing the nodes
            // This option should be used only when the template source is a static string, or when rendering direct to a stream.
            defer if (!self.options.own_strings) parser.ref_counter_holder.freeAll(self.allocator);

            switch (parse_result) {
                .Error => |err| {
                    self.result = .{
                        .Error = err,
                    };
                    return err.error_code;
                },
                .Nodes => |nodes| {
                    const elements = try parser.createElements(null, nodes);
                    try action(context, self, elements);
                },
                .Done => break,
            }
        }
    }

    pub fn deinit(self: *Self) void {
        switch (self.result) {
            .Elements => |elements| Element.freeMany(self.allocator, true, elements),
            .Error, .NotLoaded => {},
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

const tests = struct {
    test {
        _ = comments;
        _ = delimiters;
        _ = interpolation;
        _ = sections;
        _ = inverted;
        _ = partials;
    }

    pub fn getTemplate(template_text: []const u8) !Template {
        const allocator = testing.allocator;

        var template = try Template.init(allocator, template_text, .{});
        errdefer template.deinit();

        if (template.result == .Error) {
            const last_error = template.result.Error;
            std.log.err("{s} row {}, col {}", .{ @errorName(last_error.error_code), last_error.row, last_error.col });
            return last_error.error_code;
        }

        return template;
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("12345", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("12345", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);

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

            try testing.expectEqual(Element.StaticText, elements[0]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  12 ", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("12345 ", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("(", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("text", elements[1].Interpolation.key);

            try testing.expectEqual(Element.StaticText, elements[2]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("(", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("text", elements[1].Interpolation.key);

            try testing.expectEqual(Element.StaticText, elements[2]);
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

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("section", elements[1].Section.key);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 3), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("  ", section[0].StaticText);

                try testing.expectEqual(Element.Interpolation, section[1]);
                try testing.expectEqualStrings("data", section[1].Interpolation.key);

                try testing.expectEqual(Element.StaticText, section[2]);
                try testing.expectEqualStrings("\n  |data|\n", section[2].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            // Delimiters changed

            try testing.expectEqual(Element.Section, elements[2]);
            try testing.expectEqualStrings("section", elements[2].Section.key);

            if (elements[2].Section.content) |section| {
                try testing.expectEqual(@as(usize, 3), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("  {{data}}\n  ", section[0].StaticText);

                try testing.expectEqual(Element.Interpolation, section[1]);
                try testing.expectEqualStrings("data", section[1].Interpolation.key);

                try testing.expectEqual(Element.StaticText, section[2]);
                try testing.expectEqualStrings("\n", section[2].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[3]);
            try testing.expectEqualStrings("]", elements[3].StaticText);
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

            try testing.expectEqual(@as(usize, 4), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("[\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("section", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 3), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("  ", section[0].StaticText);

                try testing.expectEqual(Element.Interpolation, section[1]);
                try testing.expectEqualStrings("data", section[1].Interpolation.key);

                try testing.expectEqual(Element.StaticText, section[2]);
                try testing.expectEqualStrings("\n  |data|\n", section[2].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            // Delimiters changed

            try testing.expectEqual(Element.Section, elements[2]);
            try testing.expectEqualStrings("section", elements[2].Section.key);
            try testing.expectEqual(true, elements[2].Section.inverted);

            if (elements[2].Section.content) |section| {
                try testing.expectEqual(@as(usize, 3), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("  {{data}}\n  ", section[0].StaticText);

                try testing.expectEqual(Element.Interpolation, section[1]);
                try testing.expectEqualStrings("data", section[1].Interpolation.key);

                try testing.expectEqual(Element.StaticText, section[2]);
                try testing.expectEqualStrings("\n", section[2].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[3]);
            try testing.expectEqualStrings("]", elements[3].StaticText);
        }

        //
        // Surrounding whitespace should be left untouched.
        test "Surrounding Whitespace" {
            const template_text = "| {{=@ @=}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Begin.\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);

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

            try testing.expectEqual(Element.StaticText, elements[0]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Hello from {Mustache}!", elements[0].StaticText);
        }

        // Unadorned tags should interpolate content into the template.
        test "Basic Interpolation" {
            const template_text = "Hello, {{subject}}!";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("Hello, ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("subject", elements[1].Interpolation.key);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("!", elements[2].StaticText);
        }

        // Basic interpolation should be HTML escaped.
        test "HTML Escaping" {
            const template_text = "These characters should be HTML escaped: {{forbidden}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("forbidden", elements[1].Interpolation.key);
            try testing.expectEqual(true, elements[1].Interpolation.escaped);
        }

        // Triple mustaches should interpolate without HTML escaping.
        test "Triple Mustache" {
            const template_text = "These characters should not be HTML escaped: {{{forbidden}}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("forbidden", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);
        }

        // Ampersand should interpolate without HTML escaping.
        test "Ampersand" {
            const template_text = "These characters should not be HTML escaped: {{&forbidden}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("These characters should not be HTML escaped: ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("forbidden", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Interpolation - Surrounding Whitespace" {
            const template_text = "| {{string}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(true, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Surrounding Whitespace" {
            const template_text = "| {{{string}}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Ampersand - Surrounding Whitespace" {
            const template_text = "| {{&string}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Interpolation - Standalone" {
            const template_text = "  {{string}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(true, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Standalone" {
            const template_text = "  {{{string}}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Ampersand - Standalone" {
            const template_text = "  {{&string}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("\n", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Interpolation With Padding" {
            const template_text = "|{{ string }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(true, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Triple Mustache With Padding" {
            const template_text = "|{{{ string }}}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Ampersand With Padding" {
            const template_text = "|{{& string }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("string", elements[1].Interpolation.key);
            try testing.expectEqual(false, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
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

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("\t|\t", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" | \n", elements[2].StaticText);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{#boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 2), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings(" ", section[0].StaticText);

                try testing.expectEqual(Element.StaticText, section[1]);
                try testing.expectEqualStrings("\n ", section[1].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" | \n", elements[2].StaticText);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{#boolean}}YES{{/boolean}}\n {{#boolean}}GOOD{{/boolean}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("YES", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("\n ", elements[2].StaticText);

            try testing.expectEqual(Element.Section, elements[3]);
            try testing.expectEqualStrings("boolean", elements[3].Section.key);
            try testing.expectEqual(false, elements[3].Section.inverted);

            if (elements[3].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("GOOD", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[4]);
            try testing.expectEqualStrings("\n", elements[4].StaticText);
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

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("|\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("| A Line", elements[2].StaticText);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{#boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 0), section.len);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{#boolean}}\n#{{/boolean}}\n/";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Section, elements[0]);
            try testing.expectEqualStrings("boolean", elements[0].Section.key);
            try testing.expectEqual(false, elements[0].Section.inverted);

            if (elements[0].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("#", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[1]);
            try testing.expectEqualStrings("\n/", elements[1].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "#{{#boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("#", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("\n/\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }
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

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("|\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("| A Line", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{# boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(false, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("=", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }
    };

    const inverted = struct {

        // Sections should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = " | {{^boolean}}\t|\t{{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("\t|\t", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" | \n", elements[2].StaticText);
        }

        // Sections should not alter internal whitespace.
        test "Internal Whitespace" {
            const template_text = " | {{^boolean}} {{! Important Whitespace }}\n {{/boolean}} | \n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" | ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 2), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings(" ", section[0].StaticText);

                try testing.expectEqual(Element.StaticText, section[1]);
                try testing.expectEqualStrings("\n ", section[1].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" | \n", elements[2].StaticText);
        }

        // Single-line sections should not alter surrounding whitespace.
        test "Indented Inline Sections" {
            const template_text = " {{^boolean}}NO{{/boolean}}\n {{^boolean}}WAY{{/boolean}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(" ", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("NO", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("\n ", elements[2].StaticText);

            try testing.expectEqual(Element.Section, elements[3]);
            try testing.expectEqualStrings("boolean", elements[3].Section.key);
            try testing.expectEqual(true, elements[3].Section.inverted);

            if (elements[3].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("WAY", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[4]);
            try testing.expectEqualStrings("\n", elements[4].StaticText);
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

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("|\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("| A Line", elements[2].StaticText);
        }

        // Indented standalone lines should be removed from the template.
        test "Indented Standalone Lines" {
            const template_text = "|\r\n{{^boolean}}\r\n{{/boolean}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 0), section.len);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{^boolean}}\n^{{/boolean}}\n/";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Section, elements[0]);
            try testing.expectEqualStrings("boolean", elements[0].Section.key);
            try testing.expectEqual(true, elements[0].Section.inverted);

            if (elements[0].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("^", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[1]);
            try testing.expectEqualStrings("\n/", elements[1].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = "^{{^boolean}}\n/\n  {{/boolean}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("^", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("\n/\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }
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

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| This Is\n", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("|\n", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("| A Line", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{^ boolean }}={{/ boolean }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Section, elements[1]);
            try testing.expectEqualStrings("boolean", elements[1].Section.key);
            try testing.expectEqual(true, elements[1].Section.inverted);

            if (elements[1].Section.content) |section| {
                try testing.expectEqual(@as(usize, 1), section.len);

                try testing.expectEqual(Element.StaticText, section[0]);
                try testing.expectEqualStrings("=", section[0].StaticText);
            } else {
                try testing.expect(false);
                unreachable;
            }

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }
    };

    const partials = struct {

        // The greater-than operator should not alter surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "| {{>partial}} |";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("| ", elements[0].StaticText);

            try testing.expectEqual(Element.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation == null);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings(" |", elements[2].StaticText);
        }

        // Whitespace should be left untouched.
        test "Inline Indentation" {
            const template_text = "  {{data}}  {{> partial}}\n";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 5), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  ", elements[0].StaticText);

            try testing.expectEqual(Element.Interpolation, elements[1]);
            try testing.expectEqualStrings("data", elements[1].Interpolation.key);
            try testing.expectEqual(true, elements[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("  ", elements[2].StaticText);

            try testing.expectEqual(Element.Partial, elements[3]);
            try testing.expectEqualStrings("partial", elements[3].Partial.key);
            try testing.expect(elements[3].Partial.indentation == null);

            try testing.expectEqual(Element.StaticText, elements[4]);
            try testing.expectEqualStrings("\n", elements[4].StaticText);
        }

        // "\r\n" should be considered a newline for standalone tags.
        test "Standalone Line Endings" {
            const template_text = "|\r\n{{>partial}}\r\n|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation == null);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }

        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "  {{>partial}}\n>";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.Partial, elements[0]);
            try testing.expectEqualStrings("partial", elements[0].Partial.key);
            try testing.expect(elements[0].Partial.indentation != null);
            try testing.expectEqualStrings("  ", elements[0].Partial.indentation.?);

            try testing.expectEqual(Element.StaticText, elements[1]);
            try testing.expectEqualStrings(">", elements[1].StaticText);
        }

        // Standalone tags should not require a newline to follow them.
        test "Standalone Without Newline" {
            const template_text = ">\n  {{>partial}}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings(">\n", elements[0].StaticText);

            try testing.expectEqual(Element.Partial, elements[1]);
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

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  \\\n", elements[0].StaticText);

            try testing.expectEqual(Element.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);
            try testing.expect(elements[1].Partial.indentation != null);
            try testing.expectEqualStrings("   ", elements[1].Partial.indentation.?);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("  /", elements[2].StaticText);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Padding" {
            const template_text = "|{{> partial }}|";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.result.Elements;

            try testing.expectEqual(@as(usize, 3), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|", elements[0].StaticText);

            try testing.expectEqual(Element.Partial, elements[1]);
            try testing.expectEqualStrings("partial", elements[1].Partial.key);

            try testing.expectEqual(Element.StaticText, elements[2]);
            try testing.expectEqualStrings("|", elements[2].StaticText);
        }
    };

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

        const allocator = testing.allocator;

        var template = try Template.init(allocator, template_text, .{});
        defer template.deinit();

        try testing.expect(template.result == .Elements);
        const elements = template.result.Elements;

        try testing.expectEqual(@as(usize, 3), elements.len);

        try testing.expectEqual(Element.StaticText, elements[0]);
        try testing.expectEqualStrings("  Hello\n", elements[0].StaticText);

        try testing.expectEqual(Element.Section, elements[1]);
        try testing.expectEqualStrings("section", elements[1].Section.key);
        if (elements[1].Section.content) |section| {
            try testing.expectEqual(@as(usize, 7), section.len);

            try testing.expectEqual(Element.StaticText, section[0]);
            try testing.expectEqualStrings("Name: ", section[0].StaticText);

            try testing.expectEqual(Element.Interpolation, section[1]);
            try testing.expectEqualStrings("name", section[1].Interpolation.key);
            try testing.expectEqual(true, section[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, section[2]);
            try testing.expectEqualStrings("\nComments: ", section[2].StaticText);

            try testing.expectEqual(Element.Interpolation, section[3]);
            try testing.expectEqualStrings("comments", section[3].Interpolation.key);
            try testing.expectEqual(false, section[3].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, section[4]);
            try testing.expectEqualStrings("\n", section[4].StaticText);

            try testing.expectEqual(Element.Section, section[5]);
            try testing.expectEqualStrings("inverted", section[5].Section.key);
            try testing.expectEqual(true, section[5].Section.inverted);

            if (section[5].Section.content) |inverted_section| {
                try testing.expectEqual(@as(usize, 1), inverted_section.len);

                try testing.expectEqual(Element.StaticText, inverted_section[0]);
                try testing.expectEqualStrings("Inverted text", inverted_section[0].StaticText);
            } else {
                try testing.expect(false);
            }

            try testing.expectEqual(Element.StaticText, section[6]);
            try testing.expectEqualStrings("\n", section[6].StaticText);
        } else {
            try testing.expect(false);
        }

        try testing.expectEqual(Element.StaticText, elements[2]);
        try testing.expectEqualStrings("World", elements[2].StaticText);
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
        var template = try Template.initFromFile(allocator, absolute_file_path, .{ .read_buffer_size = read_buffer_size });
        defer template.deinit();

        try testing.expect(template.result == .Elements);
        const elements = template.result.Elements;

        try testing.expectEqual(@as(usize, 3), elements.len);

        try testing.expectEqual(Element.StaticText, elements[0]);
        try testing.expectEqualStrings("  Hello\n", elements[0].StaticText);

        try testing.expectEqual(Element.Section, elements[1]);
        try testing.expectEqualStrings("section", elements[1].Section.key);
        if (elements[1].Section.content) |section| {
            try testing.expectEqual(@as(usize, 7), section.len);

            try testing.expectEqual(Element.StaticText, section[0]);
            try testing.expectEqualStrings("Name: ", section[0].StaticText);

            try testing.expectEqual(Element.Interpolation, section[1]);
            try testing.expectEqualStrings("name", section[1].Interpolation.key);
            try testing.expectEqual(true, section[1].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, section[2]);
            try testing.expectEqualStrings("\nComments: ", section[2].StaticText);

            try testing.expectEqual(Element.Interpolation, section[3]);
            try testing.expectEqualStrings("comments", section[3].Interpolation.key);
            try testing.expectEqual(false, section[3].Interpolation.escaped);

            try testing.expectEqual(Element.StaticText, section[4]);
            try testing.expectEqualStrings("\n", section[4].StaticText);

            try testing.expectEqual(Element.Section, section[5]);
            try testing.expectEqualStrings("inverted", section[5].Section.key);
            try testing.expectEqual(true, section[5].Section.inverted);

            if (section[5].Section.content) |inverted_section| {
                try testing.expectEqual(@as(usize, 1), inverted_section.len);

                try testing.expectEqual(Element.StaticText, inverted_section[0]);
                try testing.expectEqualStrings("Inverted text", inverted_section[0].StaticText);
            } else {
                try testing.expect(false);
            }

            try testing.expectEqual(Element.StaticText, section[6]);
            try testing.expectEqualStrings("\n", section[6].StaticText);
        } else {
            try testing.expect(false);
        }

        try testing.expectEqual(Element.StaticText, elements[2]);
        try testing.expectEqualStrings("World", elements[2].StaticText);
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

        // 16KB should be enough memory for this job
        var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
            .requested_memory_limit = 16 * 1024,
        };
        defer _ = plenty_of_memory.deinit();

        // Strings are not ownned by the template,
        // Use this option when creating templates from a static string or when rendering direct to a stream
        const OWN_STRINGS = false;

        // Create a template to parse and render this 10MB file, with only 16KB of memory
        var template = Template{
            .allocator = plenty_of_memory.allocator(),
            .options = .{
                .own_strings = OWN_STRINGS,
            },
        };

        defer template.deinit();

        // A dummy render, just count the produced elements
        const DummyRender = struct {
            count: usize = 0,

            pub fn action(self: *@This(), _template: *Template, elements: []Element) anyerror!void {
                self.count += elements.len;

                checkStrings(elements);
                Element.freeMany(_template.allocator, _template.options.own_strings, elements);
            }

            // Check if all strings are valid
            // As long we are running with own_string = false,
            // Those strings must be valid during the render process
            fn checkStrings(elements: ?[]const Element) void {
                if (elements) |any| {
                    for (any) |element| {
                        switch (element) {
                            .StaticText => |item| scan(item),
                            .Interpolation => |item| scan(item.key),
                            .Partial => |item| scan(item.key),
                            .Section => |item| {
                                scan(item.key);
                                checkStrings(item.content);
                            },
                            .Parent => |item| {
                                scan(item.key);
                                checkStrings(item.content);
                            },
                            .Block => |item| {
                                scan(item.key);
                                checkStrings(item.content);
                            },
                        }
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
        };

        var dummy_render = DummyRender{};
        try template.renderFromFile(test_10MB_file, &dummy_render, DummyRender.action);

        try testing.expectEqual(@as(usize, 3 * REPEAT), dummy_render.count);
    }
};
