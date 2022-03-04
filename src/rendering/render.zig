const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const mustache = @import("../mustache.zig");
const Element = mustache.template.Element;
const Template = mustache.template.Template;
const Interpolation = mustache.template.Interpolation;

const context = @import("context.zig");
const Context = context.Context;

pub fn renderAlloc(allocator: Allocator, data: anytype, elements: []const Element) Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).init(allocator);
    errdefer builder.deinit();

    var writer = builder.writer();

    var render = getRender(allocator, writer, data);
    try render.render(elements);

    return builder.toOwnedSlice();
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

        const Stack = struct {
            parent: ?*Stack,
            ctx: Context(Writer),
        };

        allocator: Allocator,
        writer: Writer,
        data: Data,

        pub fn render(self: *Self, elements: []const Element) (Allocator.Error || Writer.Error)!void {
            var stack = Stack{
                .parent = null,
                .ctx = try context.getContext(self.allocator, self.writer, self.data),
            };
            defer stack.ctx.deinit(self.allocator);

            try self.renderLevel(&stack, elements);
        }

        fn renderLevel(self: *Self, stack: *Stack, children: ?[]const Element) (Allocator.Error || Writer.Error)!void {
            if (children) |elements| {
                for (elements) |element| {
                    switch (element) {
                        .StaticText => |content| try self.writer.writeAll(content),
                        .Interpolation => |interpolation| try interpolate(stack, interpolation),
                        .Section => |section| {
                            var iterator = stack.ctx.iterator(section.key);
                            if (section.inverted) {
                                if (try iterator.next(self.allocator)) |some| {
                                    some.deinit(self.allocator);
                                } else {
                                    try self.renderLevel(stack, section.content);
                                }
                            } else {
                                while (try iterator.next(self.allocator)) |item_ctx| {
                                    var next_step = Stack{
                                        .parent = stack,
                                        .ctx = item_ctx,
                                    };

                                    defer next_step.ctx.deinit(self.allocator);
                                    try self.renderLevel(&next_step, section.content);
                                }
                            }
                        },
                        //TODO Partial, Parent, Block
                        else => {},
                    }
                }
            }
        }

        fn interpolate(ctx: *Stack, interpolation: Interpolation) Writer.Error!void {
            var level: ?*Stack = ctx;
            while (level) |current| : (level = current.parent) {
                const success = try current.ctx.write(interpolation.key, if (interpolation.escaped) .Escaped else .Unescaped);
                if (success) break;
            }
        }
    };
}

test {
    testing.refAllDecls(@This());
}

const tests = struct {
    test {
        _ = interpolation;
    }

    /// Those tests are a verbatim copy from
    /// https://github.com/mustache/spec/blob/master/specs/interpolation.yml  
    const interpolation = struct {

        // Mustache-free templates should render as-is.
        test "No Interpolation" {
            const template_text = "Hello from {Mustache}!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var result = try renderAlloc(allocator, {}, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("Hello from {Mustache}!", result);
        }

        // Unadorned tags should interpolate content into the template.
        test "Basic Interpolation" {
            const template_text = "Hello, {{subject}}!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .subject = "world",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("Hello, world!", result);
        }

        // Basic interpolation should be HTML escaped.
        test "HTML Escaping" {
            const template_text = "These characters should be HTML escaped: {{forbidden}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .forbidden = "& \" < >",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should be HTML escaped: &amp; &quot; &lt; &gt;", result);
        }

        // Triple mustaches should interpolate without HTML escaping.
        test "Triple Mustache" {
            const template_text = "These characters should not be HTML escaped: {{{forbidden}}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .forbidden = "& \" < >",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should not be HTML escaped: & \" < >", result);
        }

        // Ampersand should interpolate without HTML escaping.
        test "Ampersand" {
            const template_text = "These characters should not be HTML escaped: {{&forbidden}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .forbidden = "& \" < >",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should not be HTML escaped: & \" < >", result);
        }

        // Integers should interpolate seamlessly.
        test "Basic Integer Interpolation" {
            const template_text = "{{mph}} miles an hour!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .mph = 85,
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("85 miles an hour!", result);
        }

        // Integers should interpolate seamlessly.
        test "Triple Mustache Integer Interpolation" {
            const template_text = "{{{mph}}} miles an hour!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .mph = 85,
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("85 miles an hour!", result);
        }

        // Integers should interpolate seamlessly.
        test "Ampersand Integer Interpolation" {
            const template_text = "{{&mph}} miles an hour!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .mph = 85,
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("85 miles an hour!", result);
        }

        // Decimals should interpolate seamlessly with proper significance.
        test "Basic Decimal Interpolation" {
            if (true) return error.SkipZigTest;

            const template_text = "{{power}} jiggawatts!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // f32

                const Data = struct {
                    power: f32,
                };

                var data = Data{
                    .power = 1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("1.21 jiggawatts!", result);
            }

            {
                // f64

                const Data = struct {
                    power: f64,
                };

                var data = Data{
                    .power = 1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("1.21 jiggawatts!", result);
            }

            {
                // Comptime float
                var data = .{
                    .power = 1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("1.21 jiggawatts!", result);
            }

            {
                // Comptime negative float
                var data = .{
                    .power = -1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("-1.21 jiggawatts!", result);
            }
        }

        // Decimals should interpolate seamlessly with proper significance.
        test "Triple Mustache Decimal Interpolation" {
            const template_text = "{{{power}}} jiggawatts!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // Comptime float
                var data = .{
                    .power = 1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("1.21 jiggawatts!", result);
            }

            {
                // Comptime negative float
                var data = .{
                    .power = -1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("-1.21 jiggawatts!", result);
            }
        }

        // Decimals should interpolate seamlessly with proper significance.
        test "Ampersand Decimal Interpolation" {
            const template_text = "{{&power}} jiggawatts!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // Comptime float
                var data = .{
                    .power = 1.210,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("1.21 jiggawatts!", result);
            }
        }

        // Nulls should interpolate as the empty string.
        test "Basic Null Interpolation" {
            const template_text = "I ({{cannot}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // Optional null

                const Data = struct {
                    cannot: ?[]const u8,
                };

                var data = Data{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }

            {
                // Comptime null

                var data = .{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }
        }

        // Nulls should interpolate as the empty string.
        test "Triple Mustache Null Interpolation" {
            const template_text = "I ({{{cannot}}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // Optional null

                const Data = struct {
                    cannot: ?[]const u8,
                };

                var data = Data{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }

            {
                // Comptime null

                var data = .{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }
        }

        // Nulls should interpolate as the empty string.
        test "Ampersand Null Interpolation" {
            const template_text = "I ({{&cannot}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // Optional null

                const Data = struct {
                    cannot: ?[]const u8,
                };

                var data = Data{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }

            {
                // Comptime null

                var data = .{
                    .cannot = null,
                };

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("I () be seen!", result);
            }
        }

        // Failed context lookups should default to empty strings.
        test "Basic Context Miss Interpolation" {
            const template_text = "I ({{cannot}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{};

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("I () be seen!", result);
        }

        // Failed context lookups should default to empty strings.
        test "Triple Mustache Context Miss Interpolation" {
            const template_text = "I ({{{cannot}}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{};

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("I () be seen!", result);
        }

        // Failed context lookups should default to empty strings
        test "Ampersand Context Miss Interpolation" {
            const template_text = "I ({{&cannot}}) be seen!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{};

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("I () be seen!", result);
        }

        // Dotted names should be considered a form of shorthand for sections.
        test "Dotted Names - Basic Interpolation" {
            const template_text = "'{{person.name}}' == '{{#person}}{{name}}{{/person}}'";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .person = .{
                    .name = "Joe",
                },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'Joe' == 'Joe'", result);
        }

        // Dotted names should be considered a form of shorthand for sections.
        test "Dotted Names - Triple Mustache Interpolation" {
            const template_text = "'{{{person.name}}}' == '{{#person}}{{{name}}}{{/person}}'";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .person = .{
                    .name = "Joe",
                },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'Joe' == 'Joe'", result);
        }

        // Dotted names should be considered a form of shorthand for sections.
        test "Dotted Names - Ampersand Interpolation" {
            const template_text = "'{{&person.name}}' == '{{#person}}{{&name}}{{/person}}'";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .person = .{
                    .name = "Joe",
                },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'Joe' == 'Joe'", result);
        }

        // Dotted names should be functional to any level of nesting.
        test "Dotted Names - Arbitrary Depth" {
            const template_text = "'{{a.b.c.d.e.name}}' == 'Phil'";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .a = .{ .b = .{ .c = .{ .d = .{ .e = .{ .name = "Phil" } } } } },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'Phil' == 'Phil'", result);
        }

        // Any falsey value prior to the last part of the name should yield ''
        test "Dotted Names - Broken Chains" {
            const template_text = "'{{a.b.c}}' == ''";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .a = .{},
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'' == ''", result);
        }

        // Each part of a dotted name should resolve only against its parent.
        test "Dotted Names - Broken Chain Resolution" {
            const template_text = "'{{a.b.c.name}}' == ''";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .a = .{ .b = .{} },
                .c = .{ .name = "Jim" },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'' == ''", result);
        }

        // The first part of a dotted name should resolve as any other name.
        test "Dotted Names - Initial Resolution" {
            const template_text = "'{{#a}}{{b.c.d.e.name}}{{/a}}' == 'Phil'";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .a = .{ .b = .{ .c = .{ .d = .{ .e = .{ .name = "Phil" } } } } },
                .b = .{ .c = .{ .d = .{ .e = .{ .name = "Wrong" } } } },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("'Phil' == 'Phil'", result);
        }

        // Dotted names should be resolved against former resolutions.
        test "Dotted Names - Context Precedence" {
            const template_text = "{{#a}}{{b.c}}{{/a}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = .{
                .a = .{ .b = .{} },
                .b = .{ .c = "ERROR" },
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("", result);
        }

        // Unadorned tags should interpolate content into the template.
        test "Implicit Iterators - Basic Interpolation" {
            const template_text = "Hello, {{.}}!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = "world";

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("Hello, world!", result);
        }

        // Basic interpolation should be HTML escaped..
        test "Implicit Iterators - HTML Escaping" {
            const template_text = "These characters should be HTML escaped: {{.}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = "& \" < >";

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should be HTML escaped: &amp; &quot; &lt; &gt;", result);
        }

        // Triple mustaches should interpolate without HTML escaping.
        test "Implicit Iterators - Triple Mustache" {
            const template_text = "These characters should not be HTML escaped: {{{.}}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = "& \" < >";

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should not be HTML escaped: & \" < >", result);
        }

        // Ampersand should interpolate without HTML escaping.
        test "Implicit Iterators - Ampersand" {
            const template_text = "These characters should not be HTML escaped: {{&.}}";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            var data = "& \" < >";

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("These characters should not be HTML escaped: & \" < >", result);
        }

        // Integers should interpolate seamlessly.
        test "Implicit Iterators - Basic Integer Interpolation" {
            const template_text = "{{.}} miles an hour!";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            {
                // runtime int
                const data: i32 = 85;

                var result = try renderAlloc(allocator, data, elements);
                defer allocator.free(result);

                try testing.expectEqualStrings("85 miles an hour!", result);
            }
        }

        // Interpolation should not alter surrounding whitespace.
        test "Interpolation - Surrounding Whitespace" {
            const template_text = "| {{string}} |";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("| --- |", result);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Surrounding Whitespace" {
            const template_text = "| {{{string}}} |";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("| --- |", result);
        }

        // Interpolation should not alter surrounding whitespace.
        test "Ampersand - Surrounding Whitespace" {
            const template_text = "| {{&string}} |";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("| --- |", result);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Interpolation - Standalone" {
            const template_text = "  {{string}}\n";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("  ---\n", result);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Triple Mustache - Standalone" {
            const template_text = "  {{{string}}}\n";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("  ---\n", result);
        }

        // Standalone interpolation should not alter surrounding whitespace.
        test "Ampersand - Standalone" {
            const template_text = "  {{&string}}\n";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("  ---\n", result);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Interpolation With Padding" {
            const template_text = "|{{ string }}|";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("|---|", result);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Triple Mustache With Padding" {
            const template_text = "|{{{ string }}}|";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("|---|", result);
        }

        // Superfluous in-tag whitespace should be ignored.
        test "Ampersand With Padding" {
            const template_text = "|{{& string }}|";

            const allocator = testing.allocator;

            var template = try Template(.{}).init(allocator, template_text);
            defer template.deinit();

            try testing.expect(template.result == .Elements);
            const elements = template.result.Elements;

            const data = .{
                .string = "---",
            };

            var result = try renderAlloc(allocator, data, elements);
            defer allocator.free(result);

            try testing.expectEqualStrings("|---|", result);
        }
    };
};
