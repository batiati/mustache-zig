const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const TemplateOptions = mustache.TemplateOptions;
const Error = mustache.Error;
const MustacheError = mustache.MustacheError;
const Template = mustache.template.Template;

const scanner = @import("scanner.zig");
const tokens = scanner.tokens;
const TextPart = scanner.TextPart;
const PartType = scanner.PartType;
const Mark = scanner.Mark;

const Element = mustache.parser.Element;
const Interpolation = mustache.parser.Interpolation;
const Section = mustache.parser.Section;
const Partials = mustache.parser.Partials;
const Inheritance = mustache.parser.Inheritance;

const assert = std.debug.assert;
const testing = std.testing;

const State = enum {
    WaitingStaringTag,
    WaitingEndingTag,
};

const Self = @This();

arena: ArenaAllocator,
template_text: []const u8,
options: TemplateOptions,
state: State = .WaitingStaringTag,
last_error: ?Error = null,

pub fn init(allocator: Allocator, template_text: []const u8, options: TemplateOptions) Self {
    return Self{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .template_text = template_text,
        .options = options,
    };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn parse(self: *Self) !Template {

    const allocator = self.arena.child_allocator;

    const level_parts = self.parseText() catch {

        return Template{
            .allocator = allocator,
            .elements = null,
            .last_error = self.last_error,
        };        

    };
    
    const elements = self.createElements(allocator, level_parts) catch {

        return Template{
            .allocator = allocator,
            .elements = null,
            .last_error = self.last_error,
        };

    };

    return Template{
        .allocator = allocator,
        .elements = elements,
        .last_error = null,
    };
}

fn createElements(self: *Self, allocator: Allocator, level_parts: []const LevelPart) anyerror![]const Element {
    var list = std.ArrayList(Element).init(allocator);
    errdefer {
        for (list.items) |*element| {
            element.free(allocator);
        }

        list.deinit();
    }

    for (level_parts) |level_part| {
        const element = blk: {
            switch (level_part.part_type) {
                .StaticText => {
                    if (level_part.text_part.tail) |content| {
                        break :blk Element{
                            .StaticText = try allocator.dupe(u8, content),
                        };
                    } else {
                        // Empty tag
                        continue;
                    }
                },

                // No output
                .Comment,
                .Delimiters,
                .CloseSection,
                => continue,

                else => |part_type| {
                    const key = try self.parseIdentificator(allocator, &level_part.text_part);
                    errdefer allocator.free(key);

                    const content = if (level_part.nested_parts) |nested_parts| try self.createElements(allocator, nested_parts) else null;
                    errdefer if (content) |content_value| allocator.free(content_value);

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

        try list.append(element);
    }

    return list.toOwnedSlice();
}

fn parseText(self: *Self) ![]const LevelPart {
    const allocator = self.arena.allocator();
    const root = try Level.init(allocator, null, self.options.delimiters);

    var current_level = root;

    var text_scanner = scanner.TextScanner.init(self.template_text, self.options.delimiters);

    while (text_scanner.next()) |*text_part| {
        var part_type = (try self.matchPartType(text_part)) orelse continue;

        current_level.trimStandAloneTag(part_type, text_part);

        if (part_type == .Delimiters) {
            current_level.delimiters = try self.parseDelimiters(text_part);

            //Apply the new delimiters to the reader immediately
            text_scanner.delimiters = current_level.delimiters;
        }

        try current_level.list.append(
            .{
                .part_type = part_type,
                .text_part = text_part.*,
            },
        );

        switch (part_type) {
            .Section,
            .InvertedSection,
            .Partials,
            .Inheritance,
            => {
                var next_level = try Level.init(allocator, current_level, current_level.delimiters);
                current_level = next_level;
            },

            .CloseSection => {
                if (current_level.parent == null) {
                    return self.setLastError(MustacheError.UnexpectedCloseSection, text_part, null);
                }

                var prev_level = current_level.parent orelse {
                    return self.setLastError(MustacheError.UnexpectedCloseSection, text_part, null);
                };

                var last_part = prev_level.peek() orelse {
                    return self.setLastError(MustacheError.UnexpectedCloseSection, text_part, null);
                };

                last_part.nested_parts = current_level.endLevel();
                current_level = prev_level;

                // Restore parent level delimiters
                text_scanner.delimiters = current_level.delimiters;
            },

            else => {},
        }
    }

    if (current_level != root) {
        return self.setLastError(MustacheError.UnexpectedEof, null, null);
    }

    return current_level.endLevel();
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

fn parseIdentificator(self: *Self, allocator: Allocator, part: *const TextPart) anyerror![]const u8 {
    if (part.tail) |text| {
        var tokenizer = std.mem.tokenize(u8, text, " \t");
        if (tokenizer.next()) |token| {
            if (tokenizer.next() == null) {
                return try allocator.dupe(u8, token);
            }
        }
    }

    return self.setLastError(MustacheError.InvalidIdentifier, part, null);
}

fn setLastError(self: *Self, err: MustacheError, part: ?*const TextPart, detail: ?[]const u8) anyerror {
    self.last_error = Error{
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
    var processor = Processor.init(allocator, template_text, .{});
    defer processor.deinit();

    var template = try testParseTemplate(&processor);
    defer template.deinit();

    const elements = template.elements;
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
    var processor = Processor.init(allocator, template_text, .{});
    defer processor.deinit();

    var template = try testParseTemplate(&processor);
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
    var processor = Processor.init(allocator, template_text, .{});
    defer processor.deinit();

    var ret = try testParseText(&processor);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 4), parts.len);
        try testing.expectEqual(PartType.Comment, parts[0].part_type);

        try testing.expectEqual(PartType.StaticText, parts[1].part_type);
        try testing.expectEqualStrings("  Hello\n", parts[1].text_part.tail.?);

        try testing.expectEqual(PartType.Section, parts[2].part_type);

        try testing.expectEqual(PartType.StaticText, parts[3].part_type);
        try testing.expectEqualStrings("World", parts[3].text_part.tail.?);

        if (parts[2].nested_parts) |section| {
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
    var processor = Processor.init(allocator, template_text, .{});
    defer processor.deinit();

    var ret = try testParseText(&processor);

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

    const allocator = testing.allocator;
    var processor = Processor.init(allocator, template_text, .{});
    defer processor.deinit();

    var ret = try testParseText(&processor);

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

fn testParseText(processor: *Processor) !?[]const LevelPart {
    return processor.parseText() catch |e| {
        if (processor.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.last_error), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}

fn testParseTemplate(processor: *Processor) !Template {
    return processor.parse() catch |e| {
        if (processor.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.last_error), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}
