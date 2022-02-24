const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.template.Delimiters;

const Template = mustache.template.Template;
const Element = mustache.template.Element;
const Interpolation = mustache.template.Interpolation;
const Section = mustache.template.Section;
const Partial = mustache.template.Partial;
const Parent = mustache.template.Parent;
const Block = mustache.template.Block;
const LastError = mustache.template.LastError;

const ParseErrors = mustache.template.ParseErrors;
const ReadError = std.fs.File.ReadError;
const OpenError = std.fs.File.OpenError;
const Errors = ParseErrors || Allocator.Error || ReadError || OpenError;

const parsing = @import("parsing.zig");
const TextScanner = parsing.TextScanner;
const tokens = parsing.tokens;
const TextBlock = parsing.TextBlock;
const BlockType = parsing.BlockType;
const Mark = parsing.Mark;
const Level = parsing.Level;
const Node = parsing.Node;

const text = @import("../text.zig");

const assert = std.debug.assert;
const testing = std.testing;

const State = enum {
    WaitingStaringTag,
    WaitingEndingTag,
};

const Self = @This();

gpa: Allocator,
arena: Allocator,
reader: text.TextReader,
state: State,
root: *Level,
current_level: *Level,
last_error: ?LastError = null,

pub fn init(gpa: Allocator, arena: Allocator, template_text: []const u8, delimiters: Delimiters) Allocator.Error!Self {
    var root = try Level.init(arena, delimiters);
    const reader = try text.fromString(arena, template_text);

    return Self{
        .gpa = gpa,
        .arena = arena,
        .reader = reader,
        .state = .WaitingStaringTag,
        .root = root,
        .current_level = root,
    };
}

pub fn initFromFile(gpa: Allocator, arena: Allocator, absolute_path: []const u8, delimiters: Delimiters) Errors!Self {
    var root = try Level.init(arena, delimiters);
    const reader = try text.fromFile(arena, absolute_path);

    return Self{
        .gpa = gpa,
        .arena = arena,
        .reader = reader,
        .state = .WaitingStaringTag,
        .root = root,
        .current_level = root,
    };
}

pub fn parse(self: *Self) Allocator.Error!Template {
    const nodes = self.parseTree() catch |err| return self.fromError(err);
    const elements = self.createElements(null, nodes) catch |err| return self.fromError(err);

    return Template{
        .allocator = self.gpa,
        .result = .{ .Elements = elements },
    };
}

fn fromError(self: *Self, err: Errors) Allocator.Error!Template {
    switch (err) {
        Allocator.Error.OutOfMemory => |alloc_err| return alloc_err,
        else => |parse_err| return Template{
            .allocator = self.gpa,
            .result = .{
                .Error = self.last_error orelse .{ .error_code = parse_err },
            },
        },
    }
}

fn createElements(self: *Self, parent_key: ?[]const u8, nodes: []const *Node) Errors![]const Element {
    var list = std.ArrayListUnmanaged(Element){};
    errdefer Element.freeMany(self.gpa, list.toOwnedSlice(self.gpa));

    for (nodes) |node| {
        const element = blk: {
            switch (node.block_type) {
                .StaticText => {
                    if (node.text_block.tail) |content| {

                        //Empty strings are represented as NULL slices
                        assert(content.len > 0);

                        break :blk Element{
                            .StaticText = try self.gpa.dupe(u8, content),
                        };
                    } else {
                        // Empty tag
                        break :blk null;
                    }
                },

                .CloseSection => {
                    const parent_key_value = parent_key orelse {
                        return self.setLastError(ParseErrors.UnexpectedCloseSection, &node.text_block, null);
                    };

                    const key = try self.parseIdentificator(&node.text_block);
                    if (!std.mem.eql(u8, parent_key_value, key)) {
                        return self.setLastError(ParseErrors.ClosingTagMismatch, &node.text_block, null);
                    }

                    break :blk null;
                },

                // No output
                .Comment,
                .Delimiters,
                => break :blk null,

                else => |block_type| {
                    const key = try self.gpa.dupe(u8, try self.parseIdentificator(&node.text_block));
                    errdefer self.gpa.free(key);

                    const content = if (node.children) |children| try self.createElements(key, children) else null;
                    errdefer if (content) |content_value| Element.freeMany(self.gpa, content_value);

                    const indentation = if (node.getIndentation()) |node_indentation| try self.gpa.dupe(u8, node_indentation) else null;
                    errdefer if (indentation) |indentation_value| self.gpa.free(indentation_value);

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

                        .Partial => {
                            break :blk Element{
                                .Partial = Partial{
                                    .key = key,
                                    .indentation = indentation,
                                },
                            };
                        },

                        .Parent => {
                            break :blk Element{
                                .Parent = Parent{
                                    .key = key,
                                    .indentation = indentation,
                                    .content = content,
                                },
                            };
                        },

                        .Block => {
                            break :blk Element{
                                .Block = Block{
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

    return list.toOwnedSlice(self.gpa);
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

                    const is_triple_mustache = tag_mark.delimiter_type == .NoScapeDelimiter;
                    if (is_triple_mustache) {
                        return .NoScapeInterpolation;
                    } else {

                        // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, <, $, =, &, /)
                        return text_block.readBlockType() orelse .Interpolation;
                    }
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
    if (text_block.tail) |tail| {
        var tokenizer = std.mem.tokenize(u8, tail, " \t");
        if (tokenizer.next()) |token| {
            if (tokenizer.next() == null) {
                return token;
            }
        }
    }

    return self.setLastError(ParseErrors.InvalidIdentifier, text_block, null);
}

fn parseTree(self: *Self) Errors![]const *Node {
    var text_scanner = TextScanner.init(self.reader);
    text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
        return self.setLastError(err, null, null);
    };

    var static_text_block: ?*Node = null;

    while (try text_scanner.next()) |*text_block| {
        var block_type = (try self.matchBlockType(text_block)) orelse continue;

        // Befone adding,
        switch (block_type) {
            .StaticText => {
                if (self.current_level.current_node) |current_node| {
                    if (current_node.block_type.ignoreStaticText()) continue;
                }
            },
            .Delimiters => {

                //Apply the new delimiters to the reader immediately
                const new_delimiters = try self.parseDelimiters(text_block);

                text_scanner.setDelimiters(new_delimiters) catch |err| {
                    return self.setLastError(err, text_block, null);
                };

                self.current_level.delimiters = new_delimiters;
            },

            else => {},
        }

        // Adding,
        try self.current_level.addNode(self.arena, block_type, text_block.*);

        // After adding
        switch (block_type) {
            .StaticText => {
                static_text_block = self.current_level.current_node;
                assert(static_text_block != null);

                static_text_block.?.trimStandAlone();
            },

            .Section,
            .InvertedSection,
            .Parent,
            .Block,
            => {
                self.current_level = try self.current_level.nextLevel(self.arena);
            },

            .CloseSection => {
                self.current_level = self.current_level.endLevel(self.arena) catch |err| {
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

    if (static_text_block) |static_text| {
        if (self.current_level.current_node) |last_node| {
            static_text.trimLast(last_node);
        }
    }

    return self.root.list.toOwnedSlice(self.arena);
}

fn setLastError(self: *Self, err: ParseErrors, text_block: ?*const TextBlock, detail: ?[]const u8) ParseErrors {
    self.last_error = LastError{
        .error_code = err,
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
            try testing.expectEqualStrings("\n", section[6].text_block.tail.?);

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

fn testParseTree(parser: *Self) !?[]const *Node {
    return parser.parseTree() catch |e| {
        if (parser.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.error_code), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}

fn testParseTemplate(parser: *Self) !Template {
    return parser.parse() catch |e| {
        if (parser.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.error_code), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}
