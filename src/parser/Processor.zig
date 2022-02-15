const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const TemplateOptions = mustache.TemplateOptions;
const Error = mustache.Error;
const MustacheError = mustache.MustacheError;

const TextPart = mustache.parser.TextPart;
const TagType = mustache.parser.TagType;
const Element = mustache.parser.Element;
const Interpolation = mustache.parser.Interpolation;
const Section = mustache.parser.Section;
const Partials = mustache.parser.Partials;
const Inheritance = mustache.parser.Inheritance;
const tokens = mustache.parser.tokens;

const TagScanner = @import("TagScanner.zig");

const assert = std.debug.assert;

const LevelPart = struct {
    tag_type: TagType,
    text_part: TextPart,
    nested_parts: ?[]const LevelPart = null,
};

const Level = struct {
    const Self = @This();

    parent: ?*Level,
    delimiters: Delimiters,
    list: std.ArrayList(LevelPart),

    pub fn init(allocator: Allocator, parent: ?*Self, delimiters: Delimiters) !*Self {
        var self = try allocator.create(Self);
        self.* = .{
            .parent = parent,
            .delimiters = delimiters,
            .list = std.ArrayList(LevelPart).init(allocator),
        };

        return self;
    }

    pub fn trimStandAloneTag(self: *const Self, tag_type: TagType, part: *TextPart) void {
        if (tag_type == .StaticText) {
            if (self.peek()) |level_part| {
                if (level_part.tag_type.canBeStandAlone()) {

                    //{{! Comments block }}    <--- Trim Left this
                    //  Hello                  <--- This static text
                    part.trimStandAloneTag(.Left);
                }
            }
        } else if (tag_type.canBeStandAlone()) {
            if (self.peek()) |level_part| {
                if (level_part.tag_type == .StaticText) {

                    //Trim Right this --->   {{#section}}
                    level_part.text_part.trimStandAloneTag(.Right);
                }
            }
        }
    }

    fn peek(self: *const Self) ?*LevelPart {
        var level: ?*const Self = self;

        while (level) |current_level| {
            const items = current_level.list.items;
            if (items.len == 0) {
                level = current_level.parent;
            } else {
                return &items[items.len - 1];
            }
        }

        return null;
    }

    pub fn endLevel(self: *Self) []const LevelPart {
        const allocator = self.list.allocator;

        allocator.destroy(self);
        return self.list.toOwnedSlice();
    }
};

const State = enum {
    WaitingStaringTag,
    WaitingEndingTag,
};

pub const Processor = struct {
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

    pub fn parse(self: *Self) ![]const Element {
        var level_parts = try self.parseText();

        const allocator = self.arena.child_allocator;
        return try self.createDom(allocator, level_parts);
    }

    fn createDom(self: *Self, allocator: Allocator, level_parts: []const LevelPart) anyerror![]const Element {
        var list = std.ArrayList(Element).init(allocator);
        defer list.deinit();

        _ = self;

        for (level_parts) |level_part| {
            const element = blk: {
                switch (level_part.tag_type) {
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

                    else => |tag_type| {
                        const key = try self.parseIdentificator(allocator, &level_part.text_part);
                        errdefer allocator.free(key);

                        const content = if (level_part.nested_parts) |nested_parts| try self.createDom(allocator, nested_parts) else null;
                        errdefer if (content) |content_value| allocator.free(content_value);

                        break :blk switch (tag_type) {
                            .Interpolation,
                            .NoScapeInterpolation,
                            => {
                                break :blk Element{
                                    .Interpolation = Interpolation{
                                        .escaped = tag_type != .NoScapeInterpolation,
                                        .key = key,
                                    },
                                };
                            },

                            .Section,
                            .InvertedSection,
                            => {
                                break :blk Element{
                                    .Section = Section{
                                        .inverted = tag_type == .InvertedSection,
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

        var scanner = TagScanner.init(self.template_text, self.options.delimiters);

        while (scanner.next()) |*text_part| {
            var tag_type = (try self.matchTagType(text_part)) orelse continue;

            current_level.trimStandAloneTag(tag_type, text_part);

            if (tag_type == .Delimiters) {
                current_level.delimiters = try self.parseDelimiters(text_part);

                //Apply the new delimiters to the reader immediately
                scanner.delimiters = current_level.delimiters;
            }

            try current_level.list.append(
                .{
                    .tag_type = tag_type,
                    .text_part = text_part.*,
                },
            );

            switch (tag_type) {
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
                    scanner.delimiters = current_level.delimiters;
                },

                else => {},
            }
        }

        if (current_level != root) {
            return self.setLastError(MustacheError.UnexpectedEof, null, null);
        }

        return current_level.endLevel();
    }

    fn matchTagType(self: *Self, part: *TextPart) !?TagType {
        switch (part.event) {
            .TagMark => |tag_mark| {
                switch (self.state) {
                    .WaitingStaringTag => {
                        defer self.state = .WaitingEndingTag;

                        if (tag_mark.tag_mark_type == .Ending) {
                            return self.setLastError(MustacheError.EndingDelimiterMismatch, part, null);
                        }

                        // If there is no current action, any content is a static text
                        if (part.tail != null) {
                            return .StaticText;
                        }
                    },

                    .WaitingEndingTag => {
                        defer self.state = .WaitingStaringTag;

                        if (tag_mark.tag_mark_type == .Starting) {
                            return self.setLastError(MustacheError.StartingDelimiterMismatch, part, null);
                        }

                        // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, $, =, &, /)
                        return part.readTagType() orelse TagType.Interpolation;
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
};

const testing = std.testing;
test {
    testing.refAllDecls(@This());
}

test "DOM" {
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

    var elements = try testParse(&processor);

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

    _ = try testParse(&processor);
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
        try testing.expectEqual(TagType.Comment, parts[0].tag_type);

        try testing.expectEqual(TagType.StaticText, parts[1].tag_type);
        try testing.expectEqualStrings("  Hello\n", parts[1].text_part.tail.?);

        try testing.expectEqual(TagType.Section, parts[2].tag_type);

        try testing.expectEqual(TagType.StaticText, parts[3].tag_type);
        try testing.expectEqualStrings("World", parts[3].text_part.tail.?);

        if (parts[2].nested_parts) |section| {
            try testing.expectEqual(@as(usize, 8), section.len);
            try testing.expectEqual(TagType.StaticText, section[0].tag_type);

            try testing.expectEqual(TagType.Interpolation, section[1].tag_type);
            try testing.expectEqualStrings("name", section[1].text_part.tail.?);

            try testing.expectEqual(TagType.StaticText, section[2].tag_type);

            try testing.expectEqual(TagType.NoScapeInterpolation, section[3].tag_type);
            try testing.expectEqualStrings("comments", section[3].text_part.tail.?);

            try testing.expectEqual(TagType.StaticText, section[4].tag_type);
            try testing.expectEqualStrings("\n", section[4].text_part.tail.?);

            try testing.expectEqual(TagType.InvertedSection, section[5].tag_type);

            try testing.expectEqual(TagType.StaticText, section[6].tag_type);
            try testing.expect(section[6].text_part.tail == null);

            try testing.expectEqual(TagType.CloseSection, section[7].tag_type);
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

        try testing.expectEqual(TagType.StaticText, parts[0].tag_type);
        try testing.expect(parts[0].text_part.tail == null);

        try testing.expectEqual(TagType.Comment, parts[1].tag_type);

        try testing.expectEqual(TagType.StaticText, parts[2].tag_type);
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

        try testing.expectEqual(TagType.Delimiters, parts[0].tag_type);
        try testing.expectEqualStrings("[ ]", parts[0].text_part.tail.?);

        try testing.expectEqual(TagType.StaticText, parts[1].tag_type);
        try testing.expect(parts[1].text_part.tail == null);

        try testing.expectEqual(TagType.Interpolation, parts[2].tag_type);
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

fn testParse(processor: *Processor) ![]const Element {
    return processor.parse() catch |e| {
        if (processor.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.last_error), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}
