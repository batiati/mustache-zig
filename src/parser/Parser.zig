const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const TemplateOptions = mustache.TemplateOptions;

const Template = mustache.template.Template;
const Element = mustache.template.Element;
const Interpolation = mustache.template.Interpolation;
const Section = mustache.template.Section;
const Partials = mustache.template.Partials;
const Inheritance = mustache.template.Inheritance;
const LastError = mustache.template.LastError;

const ParseErrors = mustache.template.ParseErrors;
const Errors = ParseErrors || Allocator.Error;

const scanner = @import("scanner.zig");
const TextScanner = scanner.TextScanner;
const tokens = scanner.tokens;
const TextBlock = scanner.TextBlock;
const BlockType = scanner.BlockType;
const Mark = scanner.Mark;

const assert = std.debug.assert;
const testing = std.testing;

const State = enum {
    WaitingStaringTag,
    WaitingEndingTag,
};

const Level = struct {
    parent: ?*Level,
    delimiters: Delimiters,
    list: std.ArrayListUnmanaged(Node) = .{},

    pub fn peekNode(self: *const Level) ?*Node {
        var level: ?*const Level = self;

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
};

pub const Node = struct {
    block_type: BlockType,
    text_block: TextBlock,
    children: ?[]const Node = null,
};

const Self = @This();

gpa: Allocator,
arena: Allocator,
template_text: []const u8,
state: State,
root: *Level,
current_level: *Level,
last_error: ?LastError = null,

pub fn init(gpa: Allocator, arena: Allocator, template_text: []const u8, delimiters: Delimiters) Allocator.Error!Self {
    var root = try arena.create(Level);
    root.* = .{
        .parent = null,
        .delimiters = delimiters,
    };

    return Self{
        .gpa = gpa,
        .arena = arena,
        .template_text = template_text,
        .state = .WaitingStaringTag,
        .root = root,
        .current_level = root,
    };
}

pub fn parse(self: *Self) Allocator.Error!Template {
    const nodes = self.parseTree() catch |err| return self.fromError(err);
    const elements = self.createElements(nodes) catch |err| return self.fromError(err);

    return Template{
        .allocator = self.gpa,
        .elements = elements,
        .last_error = null,
    };
}

fn fromError(self: *Self, err: Errors) Allocator.Error!Template {
    switch (err) {
        Allocator.Error.OutOfMemory => |alloc| return alloc,
        else => return Template{
            .allocator = self.gpa,
            .elements = null,
            .last_error = self.last_error,
        },
    }
}

fn createElements(self: *Self, nodes: []const Node) Errors!?[]const Element {
    var list = std.ArrayListUnmanaged(Element){};
    errdefer Element.freeMany(self.gpa, list.toOwnedSlice(self.gpa));

    for (nodes) |node| {
        const element = blk: {
            switch (node.block_type) {
                .StaticText => {
                    if (node.text_block.tail) |content| {
                        break :blk Element{
                            .StaticText = try self.gpa.dupe(u8, content),
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

                else => |block_type| {
                    const key = try self.parseIdentificator(&node.text_block);
                    errdefer self.gpa.free(key);

                    const content = if (node.children) |children| try self.createElements(children) else null;
                    errdefer if (content) |content_value| Element.freeMany(self.gpa, content_value);

                    break :blk switch (block_type) {
                        .Interpolation,
                        .NoScapeInterpolation,
                        => {
                            break :blk Element{
                                .Interpolation = Interpolation{
                                    .escaped = block_type != .NoScapeInterpolation,
                                    .key = key,
                                },
                            };
                        },

                        .Section,
                        .InvertedSection,
                        => {
                            break :blk Element{
                                .Section = Section{
                                    .inverted = block_type == .InvertedSection,
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
            try list.append(self.gpa, valid);
        }
    }

    if (list.items.len == 0) {
        list.clearAndFree(self.gpa);
        return null;
    } else {
        return list.toOwnedSlice(self.gpa);
    }
}

fn matchBlockType(self: *Self, text_block: *TextBlock) Errors!?BlockType {
    switch (text_block.event) {
        .Mark => |tag_mark| {
            switch (self.state) {
                .WaitingStaringTag => {
                    defer self.state = .WaitingEndingTag;

                    if (tag_mark.mark_type == .Ending) {
                        return self.setLastError(ParseErrors.EndingDelimiterMismatch, text_block, null);
                    }

                    // If there is no current action, any content is a static text
                    if (text_block.tail != null) {
                        return .StaticText;
                    }
                },

                .WaitingEndingTag => {
                    defer self.state = .WaitingStaringTag;

                    if (tag_mark.mark_type == .Starting) {
                        return self.setLastError(ParseErrors.StartingDelimiterMismatch, text_block, null);
                    }

                    // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, $, =, &, /)
                    return text_block.readBlockType() orelse .Interpolation;
                },
            }
        },
        .Eof => {
            if (text_block.tail != null) {
                return .StaticText;
            }
        },
    }

    return null;
}

fn parseDelimiters(self: *Self, text_block: *TextBlock) Errors!Delimiters {
    var delimiter: ?Delimiters = if (text_block.tail) |content| blk: {

        // Delimiters are the only case of match closing tags {{= and =}}
        // Validate if the content ends with the proper "=" symbol before parsing the delimiters
        if (content[content.len - 1] != tokens.Delimiters) break :blk null;
        text_block.tail = content[0 .. content.len - 1];

        var iterator = std.mem.tokenize(u8, text_block.tail.?, " \t");

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
        return self.setLastError(ParseErrors.InvalidDelimiters, text_block, null);
    }
}

fn parseIdentificator(self: *Self, text_block: *const TextBlock) Errors![]const u8 {
    if (text_block.tail) |text| {
        var tokenizer = std.mem.tokenize(u8, text, " \t");
        if (tokenizer.next()) |token| {
            if (tokenizer.next() == null) {
                return try self.gpa.dupe(u8, token);
            }
        }
    }

    return self.setLastError(ParseErrors.InvalidIdentifier, text_block, null);
}

fn parseTree(self: *Self) Errors![]const Node {
    var text_scanner = TextScanner.init(self.template_text);
    text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
        return self.setLastError(err, null, null);
    };

    while (text_scanner.next()) |*text_block| {
        var block_type = (try self.matchBlockType(text_block)) orelse continue;

        self.trimStandAlone(block_type, text_block);

        if (block_type == .Delimiters) {

            //Apply the new delimiters to the reader immediately
            const new_delimiters = try self.parseDelimiters(text_block);
            self.current_level.delimiters = new_delimiters;

            text_scanner.setDelimiters(new_delimiters) catch |err| {
                return self.setLastError(err, text_block, null);
            };
        }

        try self.addNode(block_type, text_block);

        switch (block_type) {
            .Section,
            .InvertedSection,
            .Partials,
            .Inheritance,
            => {
                try self.nextLevel();
            },

            .CloseSection => {
                self.endLevel() catch |err| {
                    return self.setLastError(err, text_block, null);
                };

                // Restore parent delimiters
                text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                    return self.setLastError(err, text_block, null);
                };
            },

            else => {},
        }
    }

    if (self.current_level != self.root) {
        return self.setLastError(ParseErrors.UnexpectedEof, null, null);
    }

    return self.root.list.toOwnedSlice(self.arena);
}

fn addNode(self: *Self, block_type: BlockType, text_block: *const TextBlock) Allocator.Error!void {
    try self.current_level.list.append(
        self.arena,
        .{
            .block_type = block_type,
            .text_block = text_block.*,
        },
    );
}

fn nextLevel(self: *Self) Allocator.Error!void {
    var current_level = self.current_level;
    var next_level = try self.arena.create(Level);

    next_level.* = .{
        .parent = current_level,
        .delimiters = current_level.delimiters,
    };

    self.current_level = next_level;
}

fn endLevel(self: *Self) ParseErrors!void {
    var current_level = self.current_level;
    var prev_level = current_level.parent orelse return ParseErrors.UnexpectedCloseSection;
    var last_node = prev_level.peekNode() orelse return ParseErrors.UnexpectedCloseSection;

    last_node.children = current_level.list.toOwnedSlice(self.arena);
    self.arena.destroy(current_level);

    self.current_level = prev_level;
}

fn trimStandAlone(self: *const Self, block_type: BlockType, text_block: *TextBlock) void {

    // Lines containing tags without any static text or interpolation
    // must be fully removed from the rendered result
    //
    // Examples:
    //
    // 1. TRIM LEFT stand alone tags
    //
    //                                            ┌ any white space after the tag must be TRIMMED,
    //                                            ↓ including the EOL
    // var template_text = \\{{! Comments block }}
    //                     \\Hello World
    //
    // 2. TRIM RIGHT stand alone tags
    //
    //                            ┌ any white space before the tag must be trimmed,
    //                            ↓
    // var template_text = \\      {{! Comments block }}
    //                     \\Hello World
    //
    // 3. PRESERVE interpolation tags
    //
    //                                     ┌ all white space and the line break after that must be PRESERVED,
    //                                     ↓
    // var template_text = \\      {{Name}}
    //                     \\      {{Address}}
    //                            ↑
    //                            └ all white space before that must be PRESERVED,

    // abc {{! comment }}  \r\n

    if (block_type == .StaticText) {
        if (self.current_level.peekNode()) |prev_node| {

            // Shoud not exist two continous "StaticText" blocks
            assert(prev_node.block_type != .StaticText);

            if (prev_node.block_type.canBeStandAlone()) {
                _ = text_block.trimStandAlone(.Left);
            }
        }
    } else if (block_type.canBeStandAlone()) {
        if (self.current_level.peekNode()) |prev_node| {
            if (prev_node.block_type == .StaticText) {
                _ = prev_node.text_block.trimStandAlone(.Right);
            }
        }
    }
}

fn setLastError(self: *Self, err: ParseErrors, text_block: ?*const TextBlock, detail: ?[]const u8) ParseErrors {
    self.last_error = LastError{
        .last_error = err,
        .row = if (text_block) |p| p.row else 0,
        .col = if (text_block) |p| p.col else 0,
        .detail = detail,
    };

    return err;
}

test "Basic parse" {
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

    var parser = try Self.init(allocator, arena.allocator(), template_text, .{});
    var ret = try testParseTree(&parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 4), parts.len);
        try testing.expectEqual(BlockType.Comment, parts[0].block_type);

        try testing.expectEqual(BlockType.StaticText, parts[1].block_type);
        try testing.expectEqualStrings("  Hello\n", parts[1].text_block.tail.?);

        try testing.expectEqual(BlockType.Section, parts[2].block_type);

        try testing.expectEqual(BlockType.StaticText, parts[3].block_type);
        try testing.expectEqualStrings("World", parts[3].text_block.tail.?);

        if (parts[2].children) |section| {
            try testing.expectEqual(@as(usize, 8), section.len);
            try testing.expectEqual(BlockType.StaticText, section[0].block_type);

            try testing.expectEqual(BlockType.Interpolation, section[1].block_type);
            try testing.expectEqualStrings("name", section[1].text_block.tail.?);

            try testing.expectEqual(BlockType.StaticText, section[2].block_type);

            try testing.expectEqual(BlockType.NoScapeInterpolation, section[3].block_type);
            try testing.expectEqualStrings("comments", section[3].text_block.tail.?);

            try testing.expectEqual(BlockType.StaticText, section[4].block_type);
            try testing.expectEqualStrings("\n", section[4].text_block.tail.?);

            try testing.expectEqual(BlockType.InvertedSection, section[5].block_type);

            try testing.expectEqual(BlockType.StaticText, section[6].block_type);
            try testing.expect(section[6].text_block.tail == null);

            try testing.expectEqual(BlockType.CloseSection, section[7].block_type);
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

    var parser = try Self.init(allocator, arena.allocator(), template_text, .{});
    var ret = try testParseTree(&parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 3), parts.len);

        try testing.expectEqual(BlockType.StaticText, parts[0].block_type);
        try testing.expect(parts[0].text_block.tail == null);

        try testing.expectEqual(BlockType.Comment, parts[1].block_type);

        try testing.expectEqual(BlockType.StaticText, parts[2].block_type);
        try testing.expectEqualStrings("Hello", parts[2].text_block.tail.?);
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
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parser = try Self.init(allocator, arena.allocator(), template_text, .{});
    var ret = try testParseTree(&parser);

    if (ret) |parts| {
        try testing.expectEqual(@as(usize, 3), parts.len);

        try testing.expectEqual(BlockType.Delimiters, parts[0].block_type);
        try testing.expectEqualStrings("[ ]", parts[0].text_block.tail.?);

        try testing.expectEqual(BlockType.StaticText, parts[1].block_type);
        try testing.expect(parts[1].text_block.tail == null);

        try testing.expectEqual(BlockType.Interpolation, parts[2].block_type);
        try testing.expectEqualStrings("interpolation", parts[2].text_block.tail.?);
    } else {
        try testing.expect(false);
    }
}

fn testParseTree(parser: *Self) !?[]const Node {
    return parser.parseTree() catch |e| {
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
