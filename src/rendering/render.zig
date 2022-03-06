const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const mustache = @import("../mustache.zig");
const Element = mustache.template.Element;
const Template = mustache.template.Template;
const Interpolation = mustache.template.Interpolation;
const Section = mustache.template.Section;
const ParseError = mustache.template.ParseError;

const context = @import("context.zig");
const Context = context.Context;
const Escape = context.Escape;

pub fn renderAllocCached(allocator: Allocator, data: anytype, elements: []const Element) Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).init(allocator);
    errdefer builder.deinit();

    try renderCached(allocator, data, elements, builder.writer());

    return builder.toOwnedSlice();
}

pub fn renderCached(allocator: Allocator, data: anytype, elements: []const Element, out_writer: anytype) (Allocator.Error || @TypeOf(out_writer).Error)!void {
    var render = getRender(allocator, out_writer, data);
    try render.render(elements);
}

pub fn renderAllocFromString(allocator: Allocator, data: anytype, template_text: []const u8) (Allocator.Error || ParseError)![]const u8 {
    var builder = std.ArrayList(u8).init(allocator);
    errdefer builder.deinit();

    try renderFromString(allocator, data, template_text, builder.writer());

    return builder.toOwnedSlice();
}

pub fn renderFromString(allocator: Allocator, data: anytype, template_text: []const u8, out_writer: anytype) (Allocator.Error || ParseError || @TypeOf(out_writer).Error)!void {
    var template = Template(.{ .owns_string = false }){
        .allocator = allocator,
    };

    var render = getRender(allocator, out_writer, data);
    try template.collectElements(template_text, &render);
}

pub fn getRender(allocator: Allocator, out_writer: anytype, data: anytype) Render(@TypeOf(out_writer), @TypeOf(data)) {
    return Render(@TypeOf(out_writer), @TypeOf(data)){
        .allocator = allocator,
        .writer = out_writer,
        .data = data,
    };
}

fn Render(comptime Writer: type, comptime Data: type) type {
    return struct {
        const Self = @This();
        const ContextInterface = Context(Writer);

        pub const Error = Allocator.Error || Writer.Error;

        const Stack = struct {
            parent: ?*Stack,
            ctx: Context(Writer),
        };

        allocator: Allocator,
        writer: Writer,
        data: Data,

        pub fn render(self: *Self, elements: []const Element) Error!void {
            var stack = Stack{
                .parent = null,
                .ctx = try context.getContext(self.allocator, self.writer, self.data),
            };
            defer stack.ctx.deinit(self.allocator);

            try self.renderLevel(&stack, elements);
        }

        fn renderLevel(self: *Self, stack: *Stack, children: ?[]const Element) Error!void {
            if (children) |elements| {
                for (elements) |element| {
                    switch (element) {
                        .StaticText => |content| try self.writer.writeAll(content),
                        .Interpolation => |path| try interpolate(stack, path, .Escaped),
                        .UnescapedInterpolation => |path| try interpolate(stack, path, .Unescaped),
                        .Section => |section| {
                            if (self.getIterator(stack, section)) |*iterator| {
                                while (try iterator.next(self.allocator)) |item_ctx| {
                                    defer item_ctx.deinit(self.allocator);

                                    var next_level = Stack{
                                        .parent = stack,
                                        .ctx = item_ctx,
                                    };

                                    try self.renderLevel(&next_level, section.content);
                                }
                            }
                        },
                        .InvertedSection => |section| {
                            var iterator = self.getIterator(stack, section);

                            if (iterator == null or iterator.?.hasNext() == false) {
                                try self.renderLevel(stack, section.content);
                            }
                        },

                        //TODO Partial, Parent, Block
                        else => {},
                    }
                }
            }
        }

        fn interpolate(ctx: *Stack, path: []const u8, escape: Escape) Writer.Error!void {
            var level: ?*Stack = ctx;
            while (level) |current| : (level = current.parent) {
                const path_resolution = try current.ctx.write(path, escape);

                switch (path_resolution) {
                    .Resolved => {
                        // Success, break the loop
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

        fn getIterator(self: *Self, ctx: *Stack, section: Section) ?Context(Writer).Iterator {
            _ = self;
            var level: ?*Stack = ctx;

            while (level) |current| : (level = current.parent) {
                switch (current.ctx.iterator(section.key)) {
                    .Resolved => |found| return found,

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
    };
}

test {
    testing.refAllDecls(@This());
}

const tests = struct {
    test {
        _ = interpolation;
        _ = sections;
        _ = inverted;
    }

    fn expectRender(template_text: []const u8, data: anytype, expected: []const u8) anyerror!void {
        const allocator = testing.allocator;

        {
            // Cached template render
            var cached_template = try Template(.{}).init(allocator, template_text);
            defer cached_template.deinit();

            try testing.expect(cached_template.result == .Elements);
            const cached_elements = cached_template.result.Elements;

            var result = try renderAllocCached(allocator, data, cached_elements);
            defer allocator.free(result);
            try testing.expectEqualStrings(expected, result);
        }

        {
            // Streamed template render
            var result = try renderAllocFromString(allocator, data, template_text);
            defer allocator.free(result);

            try testing.expectEqualStrings(expected, result);
        }
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
};
