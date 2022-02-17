const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("mustache.zig");
const Delimiters = mustache.Delimiters;

const Parser = @import("parser/Parser.zig");

pub const ParseErrors = error{
    StartingDelimiterMismatch,
    EndingDelimiterMismatch,
    UnexpectedEof,
    UnexpectedCloseSection,
    InvalidDelimiters,
    InvalidIdentifier,
};

pub const LastError = struct {
    last_error: anyerror,
    row: usize,
    col: usize,
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

pub const Partials = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Inheritance = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Element = union(enum) {

    /// Static text
    StaticText: []const u8,

    /// Interpolation tags are used to integrate dynamic content into the template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the data to replace the tag.  A single period (`.`)
    /// indicates that the item currently sitting atop the context stack should be
    /// used; otherwise, name resolution is as follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object, the data is the value returned by the
    ///   method with the given name.
    ///   5) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// Data should be coerced into a string (and escaped, if appropriate) before
    /// interpolation.
    /// The Interpolation tags MUST NOT be treated as standalone.    
    Interpolation: Interpolation,

    /// Section tags and End Section tags are used in combination to wrap a section
    /// of the template for iteration
    /// These tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Section tag MUST be followed
    /// by an End Section tag with the same content within the same section.
    /// This tag's content names the data to replace the tag.  Name resolution is as
    /// follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object and the method with the given name has an
    ///   arity of 1, the method SHOULD be called with a String containing the
    ///   unprocessed contents of the sections; the data is the value returned.
    ///   5) Otherwise, the data is the value returned by calling the method with
    ///   the given name.
    ///   6) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// If the data is not of a list type, it is coerced into a list as follows: if
    /// the data is truthy (e.g. `!!data == true`), use a single-element list
    /// containing the data, otherwise use an empty list.
    /// For each element in the data list, the element MUST be pushed onto the
    /// context stack, the section MUST be rendered, and the element MUST be popped
    /// off the context stack.
    /// Section and End Section tags SHOULD be treated as standalone when
    /// appropriate.    
    Section: Section,

    /// Partial tags are used to expand an external template into the current
    /// template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the partial to inject.  Set Delimiter tags MUST NOT
    /// affect the parsing of a partial.  The partial MUST be rendered against the
    /// context stack local to the tag.  If the named partial cannot be found, the
    /// empty string SHOULD be used instead, as in interpolations.
    /// Partial tags SHOULD be treated as standalone when appropriate.  If this tag
    /// is used standalone, any whitespace preceding the tag should treated as
    /// indentation, and prepended to each line of the partial before rendering.    
    Partials: Partials,

    /// Like partials, Parent tags are used to expand an external template into the
    /// current template. Unlike partials, Parent tags may contain optional
    /// arguments delimited by Block tags. For this reason, Parent tags may also be
    /// referred to as Parametric Partials.
    /// The Parent tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Parent tag MUST be followed by
    /// an End Section tag with the same content within the matching Parent tag.
    /// This tag's content names the Parent template to inject. Set Delimiter tags
    /// Preceding a Parent tag MUST NOT affect the parsing of the injected external
    /// template. The Parent MUST be rendered against the context stack local to the
    /// tag. If the named Parent cannot be found, the empty string SHOULD be used
    /// instead, as in interpolations.
    /// Parent tags SHOULD be treated as standalone when appropriate. If this tag is
    /// used standalone, any whitespace preceding the tag should be treated as
    /// indentation, and prepended to each line of the Parent before rendering.
    /// The Block tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter. Each Block tag MUST be followed by
    /// an End Section tag with the same content within the matching Block tag. This
    /// tag's content determines the parameter or argument name.
    /// Block tags may appear both inside and outside of Parent tags. In both cases,
    /// they specify a position within the template that can be overridden; it is a
    /// parameter of the containing template. The template text between the Block tag
    /// and its matching End Section tag defines the default content to render when
    /// the parameter is not overridden from outside.
    /// In addition, when used inside of a Parent tag, the template text between a
    /// Block tag and its matching End Section tag defines content that replaces the
    /// default defined in the Parent template. This content is the argument passed
    /// to the Parent template.try self.parseAction(.Partial, content)
    /// The practice of injecting an external template using a Parent tag is referred
    /// to as inheritance. If the Parent tag includes a Block tag that overrides a
    /// parameter of the Parent template, this may also be referred to as
    /// substitution.
    /// Parent templates are taken from the same namespace as regular Partial
    /// templates and in fact, injecting a regular Partial is exactly equivalent to
    /// injecting a Parent without making any substitutions. Parameter and arguments
    /// names live in a namespace that is distinct from both Partials and the context.
    Inheritance: Inheritance,

    pub fn free(self: Element, allocator: Allocator) void {
        switch (self) {
            .StaticText => |content| allocator.free(content),
            .Interpolation => |interpolation| allocator.free(interpolation.key),
            .Section => |section| {
                allocator.free(section.key);
                freeMany(allocator, section.content);
            },

            .Partials => |partials| {
                allocator.free(partials.key);
                freeMany(allocator, partials.content);
            },

            .Inheritance => |inheritance| {
                allocator.free(inheritance.key);
                freeMany(allocator, inheritance.content);
            },
        }
    }

    pub fn freeMany(allocator: Allocator, many: ?[]const Element) void {
        if (many) |items| {
            for (items) |item| {
                item.free(allocator);
            }
            allocator.free(items);
        }
    }
};

pub const Template = struct {
    const Self = @This();

    allocator: Allocator,
    elements: ?[]const Element,
    last_error: ?LastError,

    pub fn init(allocator: Allocator, template_text: []const u8, delimiters: Delimiters) !Template {
        var arena = ArenaAllocator.init(allocator);
        defer arena.deinit();

        var parser = try Parser.init(allocator, arena.allocator(), template_text, delimiters);
        return try parser.parse();
    }

    pub fn deinit(self: *Self) void {
        if (self.elements) |elements| {
            Element.freeMany(self.allocator, elements);
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
    }

    pub fn getTemplate(template_text: []const u8) !Template {
        const allocator = testing.allocator;

        var template = try Template.init(allocator, template_text, .{});

        if (template.last_error) |last_error| {
            std.log.err("{s} row {}, col {}", .{ @errorName(last_error.last_error), last_error.row, last_error.col });
            return last_error.last_error;
        }

        try testing.expect(template.elements != null);

        return template;
    }

    const comments = struct {

        //
        // Comment blocks should be removed from the template.
        test "Inline" {
            const template_text = "12345{{! Comment Block! }}67890";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

            try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("|\r\n", elements[0].StaticText);

            try testing.expectEqual(Element.StaticText, elements[1]);

            //TODO:::
            //try testing.expectEqualStrings("|", elements[1].StaticText);
        }

        //
        // Standalone tags should not require a newline to precede them.
        test "Standalone Without Previous Line" {
            const template_text = "!\n  {{! I'm Still Standalone }}";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

            //try testing.expectEqual(@as(usize, 2), elements.len);

            try testing.expectEqual(Element.StaticText, elements[0]);
            try testing.expectEqualStrings("  12 ", elements[0].StaticText);

            // TODO
            //try testing.expectEqual(Element.StaticText, elements[1]);
            //try testing.expectEqualStrings("\n", elements[1].StaticText);
        }

        //
        // Comment removal should preserve surrounding whitespace.
        test "Surrounding Whitespace" {
            const template_text = "12345 {{! Comment Block! }} 67890";

            var template = try getTemplate(template_text);
            defer template.deinit();

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

            const elements = template.elements orelse unreachable;

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

        try testing.expect(template.last_error == null);

        const elements = template.elements orelse {
            try testing.expect(false);
            return;
        };

        try testing.expectEqual(@as(usize, 3), elements.len);

        try testing.expectEqual(Element.StaticText, elements[0]);
        try testing.expectEqualStrings("  Hello\n", elements[0].StaticText);

        try testing.expectEqual(Element.Section, elements[1]);
        try testing.expectEqualStrings("section", elements[1].Section.key);
        if (elements[1].Section.content) |section| {
            try testing.expectEqual(@as(usize, 6), section.len);

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
            if (section[5].Section.content) |inverted| {
                try testing.expectEqual(@as(usize, 1), inverted.len);

                try testing.expectEqual(Element.StaticText, inverted[0]);
                try testing.expectEqualStrings("Inverted text", inverted[0].StaticText);
            } else {
                try testing.expect(false);
            }
        } else {
            try testing.expect(false);
        }

        try testing.expectEqual(Element.StaticText, elements[2]);
        try testing.expectEqualStrings("World", elements[2].StaticText);
    }
};
