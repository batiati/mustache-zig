const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;
const Section = mustache.Section;
const Partial = mustache.Partial;
const Parent = mustache.Parent;
const Block = mustache.Block;
const ParseError = mustache.ParseError;
const ParseErrorDetail = mustache.ParseErrorDetail;

const TemplateOptions = mustache.options.TemplateOptions;

const assert = std.debug.assert;
const testing = std.testing;

const parsing = @import("parsing.zig");
const Delimiters = parsing.Delimiters;
const tokens = parsing.tokens;
const BlockType = parsing.BlockType;
const FileReader = parsing.FileReader;

const memory = @import("memory.zig");

pub fn Parser(comptime options: TemplateOptions) type {
    const copy_string = options.copyStrings();
    const allow_lambdas = options.features.lambdas == .Enabled;

    const RefCounter = memory.RefCounter(options);
    const RefCounterHolder = memory.RefCounterHolder(options);
    const EpochArena = memory.EpochArena(options);

    return struct {
        const Level = parsing.Level(options);
        const Node = parsing.Node(options);
        const TextBlock = parsing.TextBlock(options);
        const TextScanner = parsing.TextScanner(options);

        pub const LoadError = Allocator.Error || if (options.source == .Stream) std.fs.File.ReadError || std.fs.File.OpenError else error{};
        pub const AbortError = error{ParserAbortedError};

        pub const ParseResult = union(enum) {
            Error: ParseErrorDetail,
            Node: *Node,
            Done,
        };

        const Self = @This();

        /// General purpose allocator
        gpa: Allocator,

        /// When `options.output == .Render`, EpochArena combines two arenas, allowing to free memory each time the parser produces
        /// When the "nextEpoch" function is called, the current arena is reserved and a new one is initialized for use.
        epoch_arena: EpochArena,

        /// Text scanner instance, shoud not be accessed directly
        text_scanner: TextScanner,

        /// Root level, holding all nested nodes produced, should not be accessed direcly
        root: *Level,

        /// Current level, holding the current tag being processed
        current_level: *Level,

        /// Stores the last error ocurred parsing the content
        last_error: ?ParseErrorDetail = null,

        /// Holds a ref_counter to the read buffer for all produced elements
        ref_counter_holder: RefCounterHolder = .{},

        pub fn init(gpa: Allocator, template: []const u8, delimiters: Delimiters) if (options.source == .String) Allocator.Error!Self else FileReader(options).Error!Self {
            var epoch_arena = EpochArena.init(gpa);
            errdefer epoch_arena.deinit();

            var root = try Level.create(epoch_arena.allocator(), delimiters);

            return Self{
                .gpa = gpa,
                .epoch_arena = epoch_arena,
                .text_scanner = try TextScanner.init(gpa, template),
                .root = root,
                .current_level = root,
            };
        }

        pub fn deinit(self: *Self) void {
            self.text_scanner.deinit(self.gpa);
            self.epoch_arena.deinit();
            self.ref_counter_holder.free(self.gpa);
        }

        pub fn parse(self: *Self) LoadError!ParseResult {
            var ret = self.parseTree() catch |err| switch (err) {
                error.ParserAbortedError => return ParseResult{ .Error = self.last_error orelse unreachable },
                else => return @errSetCast(LoadError, err),
            };

            if (ret) |node| {
                return ParseResult{ .Node = node };
            } else {
                return ParseResult.Done;
            }
        }

        fn dupe(self: *Self, ref_counter: RefCounter, slice: []const u8) Allocator.Error![]const u8 {
            if (comptime copy_string) {
                return try self.gpa.dupe(u8, slice);
            } else {
                try self.ref_counter_holder.add(self.gpa, ref_counter);
                return slice;
            }
        }

        pub fn createElements(self: *Self, parent_key: ?[]const u8, iterator: *Node.Iterator) (AbortError || LoadError)![]Element {
            var list = try std.ArrayListUnmanaged(Element).initCapacity(self.gpa, iterator.len());
            errdefer list.deinit(self.gpa);
            defer Node.unRefMany(self.gpa, iterator);

            while (iterator.next()) |node| {
                const element = blk: {
                    switch (node.block_type) {
                        .StaticText => {
                            if (node.text_block.tail) |content| {

                                //Empty strings are represented as NULL slices
                                assert(content.len > 0);

                                break :blk Element{
                                    .StaticText = try self.dupe(node.text_block.ref_counter, content),
                                };
                            } else {
                                // Empty tag
                                break :blk null;
                            }
                        },

                        .CloseSection => {
                            const parent_key_value = parent_key orelse {
                                return self.abort(ParseError.UnexpectedCloseSection, &node.text_block);
                            };

                            const key = try self.parseIdentificator(&node.text_block);
                            if (!std.mem.eql(u8, parent_key_value, key)) {
                                return self.abort(ParseError.ClosingTagMismatch, &node.text_block);
                            }

                            break :blk null;
                        },

                        // No output
                        .Comment,
                        .Delimiters,
                        => break :blk null,

                        else => |block_type| {
                            const key = try self.dupe(node.text_block.ref_counter, try self.parseIdentificator(&node.text_block));
                            errdefer if (copy_string) self.gpa.free(key);

                            const content = if (node.link.child == null) null else content: {
                                var children = node.children();
                                break :content try self.createElements(key, &children);
                            };
                            errdefer if (content) |content_value| Element.deinitMany(self.gpa, copy_string, content_value);

                            const indentation = if (node.getIndentation()) |node_indentation| try self.dupe(node.text_block.ref_counter, node_indentation) else null;
                            errdefer if (copy_string) if (indentation) |indentation_value| self.gpa.free(indentation_value);

                            const inner_text: ?[]const u8 = inner_text: {
                                if (allow_lambdas) {
                                    if (node.inner_text) |*node_inner_text| {
                                        break :inner_text try self.dupe(node_inner_text.ref_counter, node_inner_text.content);
                                    }
                                }
                                break :inner_text null;
                            };
                            errdefer if (copy_string) if (inner_text) |inner_text_value| self.gpa.free(inner_text_value);

                            break :blk switch (block_type) {
                                .Interpolation => Element{ .Interpolation = key },
                                .UnescapedInterpolation => Element{ .UnescapedInterpolation = key },
                                .InvertedSection => Element{ .InvertedSection = .{ .key = key, .content = content } },
                                .Section => Element{ .Section = .{ .key = key, .content = content, .inner_text = inner_text, .delimiters = self.current_level.delimiters } },
                                .Partial => Element{ .Partial = .{ .key = key, .indentation = indentation } },
                                .Parent => Element{ .Parent = .{ .key = key, .indentation = indentation, .content = content } },
                                .Block => Element{ .Block = .{ .key = key, .content = content } },
                                .StaticText,
                                .Comment,
                                .Delimiters,
                                .CloseSection,
                                => unreachable, // Already processed
                            };
                        },
                    }
                };

                if (element) |valid| {
                    list.appendAssumeCapacity(valid);
                }
            }

            return list.toOwnedSlice(self.gpa);
        }

        fn parseDelimiters(self: *Self, text_block: *TextBlock) AbortError!Delimiters {
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
                return self.abort(ParseError.InvalidDelimiters, text_block);
            }
        }

        fn parseIdentificator(self: *Self, text_block: *const TextBlock) AbortError![]const u8 {
            if (text_block.tail) |tail| {
                var tokenizer = std.mem.tokenize(u8, tail, " \t");
                if (tokenizer.next()) |token| {
                    if (tokenizer.next() == null) {
                        return token;
                    }
                }
            }

            return self.abort(ParseError.InvalidIdentifier, text_block);
        }

        fn parseTree(self: *Self) (AbortError || LoadError)!?*Node {
            if (self.text_scanner.delimiter_max_size == 0) {
                self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                    return self.abort(err, null);
                };
            }

            const arena = self.epoch_arena.allocator();
            var static_text_block: ?*Node = null;

            while (try self.text_scanner.next(self.gpa)) |*text_block| {
                errdefer text_block.unRef(self.gpa);

                var block_type = (try self.matchBlockType(text_block)) orelse {
                    text_block.unRef(self.gpa);
                    continue;
                };

                // Befone adding,
                switch (block_type) {
                    .StaticText => {
                        if (self.current_level.current_node) |current_node| {
                            if (current_node.block_type.ignoreStaticText()) {
                                text_block.unRef(self.gpa);
                                continue;
                            }
                        }
                    },
                    .Delimiters => {

                        //Apply the new delimiters to the reader immediately
                        const new_delimiters = try self.parseDelimiters(text_block);

                        self.text_scanner.setDelimiters(new_delimiters) catch |err| {
                            return self.abort(err, text_block);
                        };

                        self.current_level.delimiters = new_delimiters;
                        text_block.unRef(self.gpa);
                    },

                    else => {},
                }

                // Adding,
                try self.current_level.addNode(arena, block_type, text_block.*);

                // After adding
                switch (block_type) {
                    .StaticText => {
                        static_text_block = self.current_level.current_node;
                        assert(static_text_block != null);

                        static_text_block.?.trimStandAlone();

                        // When options.output = .Render,
                        // A stand-alone line in the root level indicates that the previous produced nodes can be rendered
                        if (options.output == .Render) {
                            if (self.current_level == self.root and
                                static_text_block.?.text_block.left_trimming != .PreserveWhitespaces)
                            {

                                // This text_block is independent from the rest and can be yelded later
                                // Let's produce the elements parsed until now
                                if (self.root.list.removeLast()) {
                                    const node = self.root.list.finish();

                                    self.epoch_arena.nextEpoch();
                                    const new_arena = self.epoch_arena.allocator();

                                    var root = try Level.create(new_arena, self.root.delimiters);
                                    self.root = root;
                                    self.current_level = root;

                                    // Adding it again for the next iteration,
                                    try self.current_level.addNode(new_arena, block_type, static_text_block.?.text_block);
                                    return node;
                                }
                            }
                        }
                    },

                    .Section => {
                        try self.text_scanner.beginBookmark(self.gpa);
                        self.current_level = try self.current_level.nextLevel(arena);
                    },
                    .InvertedSection,
                    .Parent,
                    .Block,
                    => {
                        self.current_level = try self.current_level.nextLevel(arena);
                    },

                    .CloseSection => {
                        const ret = self.current_level.endLevel() catch |err| {
                            return self.abort(err, text_block);
                        };

                        self.current_level = ret.level;
                        if (allow_lambdas and ret.parent_node.block_type == .Section) {
                            if (try self.text_scanner.endBookmark(self.gpa)) |bookmark| {
                                ret.parent_node.inner_text = bookmark;
                            }
                        }

                        // Restore parent delimiters

                        self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                            return self.abort(err, text_block);
                        };
                    },

                    else => {},
                }
            }

            if (self.current_level != self.root) {
                return self.abort(ParseError.UnexpectedEof, null);
            }

            if (static_text_block) |static_text| {
                if (self.current_level.current_node) |last_node| {
                    static_text.trimLast(last_node);
                }
            }

            const node = self.root.list.finish();
            self.epoch_arena.nextEpoch();
            return node;
        }

        /// Matches the BlockType produced so far
        fn matchBlockType(self: *Self, text_block: *TextBlock) !?BlockType {
            switch (text_block.event) {
                .Mark => |tag_mark| {
                    switch (tag_mark.mark_type) {
                        .Starting => {

                            // If there is no current action, any content is a static text
                            if (text_block.tail != null) {
                                return .StaticText;
                            }
                        },

                        .Ending => {
                            const is_triple_mustache = tag_mark.delimiter_type == .NoScapeDelimiter;
                            if (is_triple_mustache) {
                                return .UnescapedInterpolation;
                            } else {

                                // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, <, $, =, &, /)
                                return text_block.readBlockType() orelse .Interpolation;
                            }
                        },
                    }
                },
                .Eof => {
                    switch (self.text_scanner.state) {
                        .Finished => if (text_block.tail != null) return .StaticText,
                        else => return self.abort(ParseError.UnexpectedEof, text_block),
                    }
                },
            }

            return null;
        }

        fn abort(self: *Self, err: ParseError, text_block: ?*const TextBlock) AbortError {
            self.last_error = ParseErrorDetail{
                .parse_error = err,
                .lin = if (text_block) |p| p.lin else 0,
                .col = if (text_block) |p| p.col else 0,
            };

            return AbortError.ParserAbortedError;
        }
    };
}

const StreamedParser = Parser(.{ .source = .{ .String = .{} }, .output = .Parse });

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

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var first_block = try testParseTree(&parser);

    // The parser produces only the minimun amount of tags that can be render at once
    if (first_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());
        try testing.expectEqual(BlockType.Comment, siblings.next().?.block_type);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);

    // Nested tags must be produced together
    if (second_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 2), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.StaticText, node_0.block_type);
        try testing.expectEqualStrings("  Hello\n", node_0.text_block.tail.?);

        const node_1 = siblings.next().?;
        try testing.expectEqual(BlockType.Section, node_1.block_type);

        if (node_1.link.child != null) {
            var children = node_1.children();
            try testing.expectEqual(@as(usize, 8), children.len());

            const section_0 = children.next().?;
            try testing.expectEqual(BlockType.StaticText, section_0.block_type);

            const section_1 = children.next().?;
            try testing.expectEqual(BlockType.Interpolation, section_1.block_type);
            try testing.expectEqualStrings("name", section_1.text_block.tail.?);

            const section_2 = children.next().?;
            try testing.expectEqual(BlockType.StaticText, section_2.block_type);

            const section_3 = children.next().?;
            try testing.expectEqual(BlockType.UnescapedInterpolation, section_3.block_type);
            try testing.expectEqualStrings("comments", section_3.text_block.tail.?);

            const section_4 = children.next().?;
            try testing.expectEqual(BlockType.StaticText, section_4.block_type);
            try testing.expectEqualStrings("\n", section_4.text_block.tail.?);

            const section_5 = children.next().?;
            try testing.expectEqual(BlockType.InvertedSection, section_5.block_type);

            const section_6 = children.next().?;
            try testing.expectEqual(BlockType.StaticText, section_6.block_type);
            try testing.expectEqualStrings("\n", section_6.text_block.tail.?);

            const section_7 = children.next().?;
            try testing.expectEqual(BlockType.CloseSection, section_7.block_type);
        } else {
            try testing.expect(false);
        }
    } else {
        try testing.expect(false);
    }

    var third_block = try testParseTree(&parser);

    if (third_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.StaticText, node_0.block_type);
        try testing.expectEqualStrings("World", node_0.text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var no_more = try testParseTree(&parser);
    try testing.expect(no_more == null);
}

test "Scan standAlone tags" {
    const template_text =
        \\   {{!           
        \\   Comments block 
        \\   }}            
        \\Hello
    ;

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var first_block = try testParseTree(&parser);

    // The parser produces only the minimun amount of tags that can be render at once
    if (first_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 2), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.StaticText, node_0.block_type);
        try testing.expect(node_0.text_block.tail == null);

        const node_1 = siblings.next().?;
        try testing.expectEqual(BlockType.Comment, node_1.block_type);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.StaticText, node_0.block_type);
        try testing.expectEqualStrings("Hello", node_0.text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var no_more = try testParseTree(&parser);
    try testing.expect(no_more == null);
}

test "Scan delimiters Tags" {
    const template_text =
        \\{{=[ ]=}}           
        \\[interpolation]
    ;

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    // The parser produces only the minimun amount of tags that can be render at once

    var first_block = try testParseTree(&parser);
    if (first_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.Delimiters, node_0.block_type);
        try testing.expectEqualStrings("[ ]", node_0.text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 2), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(BlockType.StaticText, node_0.block_type);
        try testing.expect(node_0.text_block.tail == null);

        const node_1 = siblings.next().?;
        try testing.expectEqual(BlockType.Interpolation, node_1.block_type);
        try testing.expectEqualStrings("interpolation", node_1.text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var no_more = try testParseTree(&parser);
    try testing.expect(no_more == null);
}

test "Parse - UnexpectedEof " {

    //                              Eof
    //                              ↓
    const template_text = "{{missing";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const err = try testParseError(&parser);
    try testing.expectEqual(ParseError.UnexpectedEof, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 10), err.col);
}

test "Parse - Malformed " {

    // It's considered a valid static text, and not an error
    // A tag should start with '{{' and contains anything except an '}}'
    const template_text = "missing}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const first_block = try testParseTree(&parser);
    if (first_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());

        const node_0 = siblings.next();
        try testing.expect(node_0 != null);
        try testing.expectEqual(BlockType.StaticText, node_0.?.block_type);
        try testing.expectEqualStrings("missing}}", node_0.?.text_block.tail.?);
    } else {
        try testing.expect(false);
    }
}

test "Parse - UnexpectedCloseSection " {

    //                                     Close section
    //                                     ↓
    const template_text = "hello{{/section}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const err = try testParseError(&parser);
    try testing.expectEqual(ParseError.UnexpectedCloseSection, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 16), err.col);
}

test "Parse - InvalidDelimiters " {

    //                                               Close section
    //                                               ↓
    const template_text = "{{= not valid delimiter =}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const err = try testParseError(&parser);
    try testing.expectEqual(ParseError.InvalidDelimiters, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 26), err.col);
}

test "Parse - InvalidDelimiters " {

    //                                               Close section
    //                                               ↓
    const template_text = "{{ not a valid identifier }}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const err = try testParseError(&parser);
    try testing.expectEqual(ParseError.InvalidIdentifier, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 27), err.col);
}

test "Parse - ClosingTagMismatch " {

    //                                          Close section
    //                                          ↓
    const template_text = "{{#hello}}...{{/world}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    const err = try testParseError(&parser);
    try testing.expectEqual(ParseError.ClosingTagMismatch, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 22), err.col);
}

fn testParseTree(parser: anytype) !?*StreamedParser.Node {
    return parser.parseTree() catch |e| {
        if (parser.last_error) |detail| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            try testing.expect(false);
        }

        return e;
    };
}

fn testParseError(parser: anytype) !ParseErrorDetail {
    const node = parser.parseTree() catch |e| {
        if (parser.last_error) |err| {
            return err;
        } else {
            return e;
        }
    };

    try testing.expect(node != null);
    var siblings = node.?.siblings();
    _ = parser.createElements(null, &siblings) catch |e| {
        if (parser.last_error) |err| {
            return err;
        } else {
            return e;
        }
    };

    try testing.expect(false);
    unreachable;
}
