const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const TemplateOptions = mustache.TemplateOptions;
const MustacheError = mustache.MustacheError;

const Template = mustache.template.Template;
const Element = mustache.template.Element;
const Interpolation = mustache.template.Interpolation;
const Section = mustache.template.Section;
const Partials = mustache.template.Partials;
const Inheritance = mustache.template.Inheritance;
const LastError = mustache.template.LastError;

const scanner = @import("scanner.zig");
const Tree = scanner.Tree;
const TextScanner = scanner.TextScanner;
const tokens = scanner.tokens;
const TextPart = scanner.TextPart;
const PartType = scanner.PartType;
const Mark = scanner.Mark;

const assert = std.debug.assert;
const testing = std.testing;

const State = enum {
    WaitingStaringTag,
    WaitingEndingTag,
};

const Self = @This();

allocator: Allocator,
template_text: []const u8,
options: TemplateOptions,
state: State = .WaitingStaringTag,
last_error: ?LastError = null,

pub fn init(allocator: Allocator, template_text: []const u8, options: TemplateOptions) Self {
    return Self{
        .allocator = allocator,
        .template_text = template_text,
        .options = options,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn parse(self: *Self) !Template {
    var arena = ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const nodes = self.parseTree(arena.allocator()) catch {
        return Template{
            .allocator = self.allocator,
            .elements = null,
            .last_error = self.last_error,
        };
    };

    const elements = self.createElements(nodes) catch {
        return Template{
            .allocator = self.allocator,
            .elements = null,
            .last_error = self.last_error,
        };
    };

    return Template{
        .allocator = self.allocator,
        .elements = elements,
        .last_error = null,
    };
}


fn createElements(self: *Self, nodes: []const Tree.Node) anyerror!?[]const Element {
    var list = std.ArrayListUnmanaged(Element) {};
    errdefer Element.freeMany(self.allocator, list.toOwnedSlice(self.allocator));

    for (nodes) |node| {
        const element = blk: {
            switch (node.part_type) {
                .StaticText => {
                    if (node.text_part.tail) |content| {
                        break :blk Element{
                            .StaticText = try self.allocator.dupe(u8, content),
                        };
                    } else {
                        // Empty tag
                        break :blk null;
                    }
                },

                // No output
                .Comment,
                .Delimiters,
                .CloseSection,
                => break :blk null,

                else => |part_type| {
                    const key = try self.parseIdentificator(&node.text_part);
                    errdefer self.allocator.free(key);

                    const content = if (node.children) |children| try self.createElements(children) else null;
                    errdefer if (content) |content_value| Element.freeMany(self.allocator, content_value);

                    break :blk switch (part_type) {
                        .Interpolation,
                        .NoScapeInterpolation,
                        => {
                            break :blk Element{
                                .Interpolation = Interpolation{
                                    .escaped = part_type != .NoScapeInterpolation,
                                    .key = key,
                                },
                            };
                        },

                        .Section,
                        .InvertedSection,
                        => {
                            break :blk Element{
                                .Section = Section{
                                    .inverted = part_type == .InvertedSection,
                                    .key = key,
                                    .content = content,
                                },
                            };
                        },

                        .Partials => {
                            break :blk Element{
                                .Partials = Partials{
                                    .key = key,
                                    .content = content,
                                },
                            };
                        },

                        .Inheritance => {
                            break :blk Element{
                                .Inheritance = Inheritance{
                                    .key = key,
                                    .content = content,
                                },
                            };
                        },

                        // Already processed
                        .StaticText,
                        .Comment,
                        .Delimiters,
                        .CloseSection,
                        => unreachable,
                    };
                },
            }
        };

        if (element) |valid| {
            try list.append(self.allocator, valid);
        }
    }

    if (list.items.len == 0) {
        list.clearAndFree(self.allocator);
        return null;
    } else {
        return list.toOwnedSlice(self.allocator) ;
    }
}

fn parseTree(self: *Self, arena: Allocator) ![]const Tree.Node {
    var tree = try Tree.init(arena, self.options.delimiters);    
    var text_scanner = TextScanner.init(self.template_text, self.options.delimiters);
    
    while (text_scanner.next()) |*text_part| {
        var part_type = (try self.matchPartType(text_part)) orelse continue;

        tree.trimStandAlone(part_type, text_part);

        if (part_type == .Delimiters) {
            const new_delimiters = try self.parseDelimiters(text_part);

            //Apply the new delimiters to the reader immediately
            tree.setCurrentDelimiters(new_delimiters);
            text_scanner.delimiters = new_delimiters;
        }

        tree.addNode(part_type, text_part) catch |err| {
            return self.setLastError(err, text_part, null);
        };

        switch (part_type) {
            .Section,
            .InvertedSection,
            .Partials,
            .Inheritance,
            => {
                tree.nextLevel() catch |err| {
                    return self.setLastError(err, text_part, null);
                };
            },

            .CloseSection => {
                tree.endLevel() catch |err| {
                    return self.setLastError(err, text_part, null);
                };

                // Restore parent delimiters
                text_scanner.delimiters = tree.getCurrentDelimiters();
            },

            else => {},
        }
    }

    return tree.endRoot() catch |err| {
        return self.setLastError(err, null, null);
    };
}

fn matchPartType(self: *Self, part: *TextPart) !?PartType {
    switch (part.event) {
        .Mark => |tag_mark| {
            switch (self.state) {
                .WaitingStaringTag => {
                    defer self.state = .WaitingEndingTag;

                    if (tag_mark.mark_type == .Ending) {
                        return self.setLastError(MustacheError.EndingDelimiterMismatch, part, null);
                    }

                    // If there is no current action, any content is a static text
                    if (part.tail != null) {
                        return .StaticText;
                    }
                },

                .WaitingEndingTag => {
                    defer self.state = .WaitingStaringTag;

                    if (tag_mark.mark_type == .Starting) {
                        return self.setLastError(MustacheError.StartingDelimiterMismatch, part, null);
                    }

                    // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, $, =, &, /)
                    return part.readPartType() orelse PartType.Interpolation;
                },
            }
        },
        .Eof => {
            if (part.tail != null) {
                return .StaticText;
            }
        },
    }

    return null;
}

fn parseDelimiters(self: *Self, part: *TextPart) !Delimiters {
    var delimiter: ?Delimiters = if (part.tail) |content| blk: {

        // Delimiters are the only case of match closing tags {{= and =}}
        // Validate if the content ends with the proper "=" symbol before parsing the delimiters
        if (content[content.len - 1] != tokens.Delimiters) break :blk null;
        part.tail = content[0 .. content.len - 1];

        var iterator = std.mem.tokenize(u8, part.tail.?, " \t");

        var starting_delimiter = iterator.next() orelse break :blk null;
        var ending_delimiter = iterator.next() orelse break :blk null;
        if (iterator.next() != null) break :blk null;

        break :blk Delimiters{
            .starting_delimiter = starting_delimiter,
            .ending_delimiter = ending_delimiter,
        };
    } else null;

    if (delimiter) |ret| {
        return ret;
    } else {
        return self.setLastError(MustacheError.InvalidDelimiters, part, null);
    }
}

fn parseIdentificator(self: *Self, part: *const TextPart) anyerror![]const u8 {
    if (part.tail) |text| {
        var tokenizer = std.mem.tokenize(u8, text, " \t");
        if (tokenizer.next()) |token| {
            if (tokenizer.next() == null) {
                return try self.allocator.dupe(u8, token);
            }
        }
    }

    return self.setLastError(MustacheError.InvalidIdentifier, part, null);
}

fn setLastError(self: *Self, err: anyerror, part: ?*const TextPart, detail: ?[]const u8) anyerror {
    self.last_error = LastError{
        .last_error = err,
        .row = if (part) |p| p.row else 0,
        .col = if (part) |p| p.col else 0,
        .detail = detail,
    };

    return err;
}

test "DOM2" {
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
    
    var parser = Self.init(allocator, template_text, .{});
    defer parser.deinit();

    var template = try testParseTemplate(&parser);
    defer template.deinit();

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

test "DOM" {
    const template_text =
        \\{{! Comments block }}
        \\  Hello
        \\  {{#section wrong}}{{/section}}
        \\World
    ;

    const allocator = testing.allocator;
    var parser = Self.init(allocator, template_text, .{});
    defer parser.deinit();

    var template = try testParseTemplate(&parser);
    defer template.deinit();
}

test "basic test" {
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
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Self.init(allocator, template_text, .{});
    defer parser.deinit();

    var ret = try testParseTree(arena.allocator(), &parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 4), parts.len);
        try testing.expectEqual(PartType.Comment, parts[0].part_type);

        try testing.expectEqual(PartType.StaticText, parts[1].part_type);
        try testing.expectEqualStrings("  Hello\n", parts[1].text_part.tail.?);

        try testing.expectEqual(PartType.Section, parts[2].part_type);

        try testing.expectEqual(PartType.StaticText, parts[3].part_type);
        try testing.expectEqualStrings("World", parts[3].text_part.tail.?);

        if (parts[2].children) |section| {
            try testing.expectEqual(@as(usize, 8), section.len);
            try testing.expectEqual(PartType.StaticText, section[0].part_type);

            try testing.expectEqual(PartType.Interpolation, section[1].part_type);
            try testing.expectEqualStrings("name", section[1].text_part.tail.?);

            try testing.expectEqual(PartType.StaticText, section[2].part_type);

            try testing.expectEqual(PartType.NoScapeInterpolation, section[3].part_type);
            try testing.expectEqualStrings("comments", section[3].text_part.tail.?);

            try testing.expectEqual(PartType.StaticText, section[4].part_type);
            try testing.expectEqualStrings("\n", section[4].text_part.tail.?);

            try testing.expectEqual(PartType.InvertedSection, section[5].part_type);

            try testing.expectEqual(PartType.StaticText, section[6].part_type);
            try testing.expect(section[6].text_part.tail == null);

            try testing.expectEqual(PartType.CloseSection, section[7].part_type);
        } else {
            try testing.expect(false);
        }
    } else {
        try testing.expect(false);
    }
}

test "Scan standAlone tags" {
    const template_text =
        \\   {{!           
        \\   Comments block 
        \\   }}            
        \\Hello
    ;

    const allocator = testing.allocator;
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = Self.init(allocator, template_text, .{});
    defer parser.deinit();

    var ret = try testParseTree(arena.allocator(), &parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 3), parts.len);

        try testing.expectEqual(PartType.StaticText, parts[0].part_type);
        try testing.expect(parts[0].text_part.tail == null);

        try testing.expectEqual(PartType.Comment, parts[1].part_type);

        try testing.expectEqual(PartType.StaticText, parts[2].part_type);
        try testing.expectEqualStrings("Hello", parts[2].text_part.tail.?);
    } else {
        try testing.expect(false);
    }
}

test "Scan delimiters Tags" {
    const template_text =
        \\{{=[ ]=}}           
        \\[interpolation]
    ;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    var allocator = arena.allocator();

    var parser = Self.init(allocator, template_text, .{});
    defer parser.deinit();

    var ret = try testParseTree(allocator, &parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 3), parts.len);

        try testing.expectEqual(PartType.Delimiters, parts[0].part_type);
        try testing.expectEqualStrings("[ ]", parts[0].text_part.tail.?);

        try testing.expectEqual(PartType.StaticText, parts[1].part_type);
        try testing.expect(parts[1].text_part.tail == null);

        try testing.expectEqual(PartType.Interpolation, parts[2].part_type);
        try testing.expectEqualStrings("interpolation", parts[2].text_part.tail.?);
    } else {
        try testing.expect(false);
    }
}

fn testParseTree(arena: Allocator, parser: *Self) !?[]const Tree.Node {
    return parser.parseTree(arena) catch |e| {
        if (parser.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.last_error), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}

fn testParseTemplate(parser: *Self) !Template {
    return parser.parse() catch |e| {
        if (parser.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.last_error), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}
