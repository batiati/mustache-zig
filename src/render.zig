const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const mustache = @import("mustache.zig");
const Element = mustache.template.Element;
const Template = mustache.template.Template;

const context = @import("context.zig");
const Context = context.Context;

pub fn renderAlloc(allocator: Allocator, data: anytype, elements: []const Element) anyerror![]const u8 {
    var builder = std.ArrayList(u8).init(allocator);
    errdefer builder.deinit();

    var writer = builder.writer();

    var render = getRender(writer, data);
    try render.render(allocator, elements);

    return builder.toOwnedSlice();
}

pub fn getRender(out_writer: anytype, data: anytype) Render(@TypeOf(out_writer), @TypeOf(data)) {
    return Render(@TypeOf(out_writer), @TypeOf(data)){
        .writer = out_writer,
        .data = data,
    };
}

fn Render(comptime Writer: type, comptime Data: type) type {
    return struct {
        const Self = @This();

        writer: Writer,
        data: Data,

        pub fn render(self: *Self, allocator: Allocator, elements: []const Element) anyerror!void {
            var ctx = try context.getContext(allocator, self.writer, self.data);
            defer ctx.deinit(allocator);

            try self.renderLevel(allocator, &ctx, elements);
        }

        fn renderLevel(self: *Self, allocator: Allocator, ctx: *Context, children: ?[]const Element) anyerror!void {
            if (children) |elements| {
                for (elements) |element| {
                    switch (element) {
                        .StaticText => |content| try self.writer.writeAll(content),
                        .Interpolation => |interpolation| _ = try ctx.write(interpolation.key, if (interpolation.escaped) .Escaped else .Unescaped),
                        .Section => |section| {
                            var iterator = ctx.iterator(section.key);
                            if (section.inverted) {
                                if (try iterator.next(allocator)) |some| {
                                    some.deinit(allocator);
                                } else {
                                    try self.renderLevel(allocator, ctx, section.content);
                                }
                            } else {
                                while (try iterator.next(allocator)) |*item_ctx| {
                                    defer item_ctx.deinit(allocator);
                                    try self.renderLevel(allocator, item_ctx, section.content);
                                }
                            }
                        },
                        //TODO
                        else => {},
                    }
                }
            }
        }
    };
}

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

// Decimals should interpolate seamlessly with proper significance.
test "Basic Decimal Interpolation" {
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

        var data = Data {
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

        var data = Data {
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

        var data = Data {
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

        var data = Data {
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