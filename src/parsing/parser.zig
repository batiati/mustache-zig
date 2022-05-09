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
const PartType = parsing.PartType;
const FileReader = parsing.FileReader;

const memory = @import("memory.zig");

const parsePath = @import("../template.zig").parsePath;

pub fn Parser(comptime options: TemplateOptions) type {
    const copy_string = options.copyStrings();
    const allow_lambdas = options.features.lambdas == .Enabled;

    const RefCounter = memory.RefCounter(options);
    const RefCounterHolder = memory.RefCounterHolder(options);
    const EpochArena = memory.EpochArena(options);

    return struct {
        const Level = parsing.Level(options);
        const Node = parsing.Node(options);
        const TextPart = parsing.TextPart(options);
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

        pub fn createElements(self: *Self, list: *std.ArrayListUnmanaged(Element), parent_key: ?[]const u8, iterator: *Node.Iterator) (AbortError || LoadError)!u32 {
            var count: u32 = 0;

            try list.ensureTotalCapacityPrecise(self.gpa, list.capacity + iterator.len());
            defer Node.unRefMany(self.gpa, iterator);

            while (iterator.next()) |node| {
                switch (node.text_part.part_type) {
                    .static_text => {

                        //Empty strings are represented as NULL slices
                        // TODO: assert(node.text_part.content.len == 0);
                        if (node.text_part.content.len == 0) {
                            node.unRef(self.gpa);
                            continue;
                        }

                        const static_text = Element{
                            .StaticText = try self.dupe(node.text_part.ref_counter, node.text_part.content),
                        };

                        list.appendAssumeCapacity(static_text);
                        count += 1;

                        continue;
                    },

                    .close_section => {
                        const parent_key_value = parent_key orelse {
                            return self.abort(ParseError.UnexpectedCloseSection, &node.text_part);
                        };

                        const key = try self.parseIdentifier(&node.text_part);

                        if (!std.mem.eql(u8, parent_key_value, key)) {
                            return self.abort(ParseError.ClosingTagMismatch, &node.text_part);
                        }

                        continue;
                    },

                    // No output
                    .comments,
                    .delimiters,
                    => continue,

                    else => |part_type| {
                        const identifier = try self.parseIdentifier(&node.text_part);

                        const indentation = if (node.getIndentation()) |node_indentation| try self.dupe(node.text_part.ref_counter, node_indentation) else null;
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

                        // Just reserve the current position to append the element,
                        // It's safe to increment the len here, since the list already had the capacity adjusted
                        const current_index = list.items.len;
                        list.items.len += 1;
                        count += 1;

                        // Add the children before adding the parent
                        // because the parent needs the children_count to be calculated
                        const children_count: u32 = if (node.link.child == null) 0 else children_count: {
                            var children = node.children();
                            const children_count = try self.createElements(list, identifier, &children);
                            count += children_count;

                            break :children_count children_count;
                        };

                        const element: Element = switch (part_type) {
                            .interpolation => .{
                                .Interpolation = try self.parsePath(node.text_part.ref_counter, identifier),
                            },
                            .no_escape, .triple_mustache => .{
                                .UnescapedInterpolation = try self.parsePath(node.text_part.ref_counter, identifier),
                            },
                            .inverted_section => .{
                                .InvertedSection = .{
                                    .path = try self.parsePath(node.text_part.ref_counter, identifier),
                                    .children_count = children_count,
                                },
                            },
                            .section => .{
                                .Section = .{
                                    .path = try self.parsePath(node.text_part.ref_counter, identifier),
                                    .children_count = children_count,
                                    .inner_text = inner_text,
                                    .delimiters = self.current_level.delimiters,
                                },
                            },
                            .partial => .{
                                .Partial = .{
                                    .key = try self.dupe(node.text_part.ref_counter, identifier),
                                    .indentation = indentation,
                                },
                            },
                            .parent => .{
                                .Parent = .{
                                    .key = try self.dupe(node.text_part.ref_counter, identifier),
                                    .children_count = children_count,
                                    .indentation = indentation,
                                },
                            },
                            .block => .{
                                .Block = .{
                                    .key = try self.dupe(node.text_part.ref_counter, identifier),
                                    .children_count = children_count,
                                },
                            },
                            .static_text,
                            .comments,
                            .delimiters,
                            .close_section,
                            => unreachable, // Already processed
                        };

                        list.items[current_index] = element;
                        continue;
                    },
                }
            }

            return count;
        }

        fn parseDelimiters(self: *Self, text_part: *TextPart) AbortError!Delimiters {
            var delimiter: ?Delimiters = blk: {
                var content = text_part.content;

                // Delimiters are the only case of match closing tags {{= and =}}
                // Validate if the content ends with the proper "=" symbol before parsing the delimiters
                if (content[content.len - 1] != @enumToInt(PartType.delimiters)) break :blk null;
                content = content[0 .. content.len - 1];

                var iterator = std.mem.tokenize(u8, content, " \t");

                var starting_delimiter = iterator.next() orelse break :blk null;
                var ending_delimiter = iterator.next() orelse break :blk null;
                if (iterator.next() != null) break :blk null;

                break :blk Delimiters{
                    .starting_delimiter = starting_delimiter,
                    .ending_delimiter = ending_delimiter,
                };
            };

            if (delimiter) |ret| {
                return ret;
            } else {
                return self.abort(ParseError.InvalidDelimiters, text_part);
            }
        }

        fn parsePath(self: *Self, ref_counter: RefCounter, identifier: []const u8) Allocator.Error!Element.Path {
            if (!copy_string) try self.ref_counter_holder.add(self.gpa, ref_counter);

            return try Element.createPath(self.gpa, copy_string, identifier);
        }

        fn parseIdentifier(self: *Self, text_part: *const TextPart) AbortError![]const u8 {
            var tokenizer = std.mem.tokenize(u8, text_part.content, " \t");
            if (tokenizer.next()) |token| {
                if (tokenizer.next() == null) {
                    return token;
                }
            }

            return self.abort(ParseError.InvalidIdentifier, text_part);
        }

        fn parseTree(self: *Self) (AbortError || LoadError)!?*Node {
            if (self.text_scanner.delimiter_max_size == 0) {
                self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                    return self.abort(err, null);
                };
            }

            const arena = self.epoch_arena.allocator();
            var static_text_part: ?*Node = null;

            while (try self.text_scanner.next(self.gpa)) |*text_part| {
                errdefer text_part.unRef(self.gpa);

                // Befone adding,
                switch (text_part.part_type) {
                    .static_text => {
                        if (self.current_level.current_node) |current_node| {
                            if (current_node.text_part.part_type.ignoreStaticText()) {
                                text_part.unRef(self.gpa);
                                continue;
                            }
                        }
                    },
                    .delimiters => {

                        //Apply the new delimiters to the reader immediately
                        const new_delimiters = try self.parseDelimiters(text_part);

                        self.text_scanner.setDelimiters(new_delimiters) catch |err| {
                            return self.abort(err, text_part);
                        };

                        self.current_level.delimiters = new_delimiters;
                        text_part.unRef(self.gpa);
                    },

                    else => {},
                }

                // Adding,
                try self.current_level.addNode(arena, text_part.*);

                // After adding
                switch (text_part.part_type) {
                    .static_text => {
                        static_text_part = self.current_level.current_node;
                        assert(static_text_part != null);

                        static_text_part.?.trimStandAlone();

                        // When options.output = .Render,
                        // A stand-alone line in the root level indicates that the previous produced nodes can be rendered
                        if (options.output == .Render) {
                            if (self.current_level == self.root and
                                static_text_part.?.text_part.left_trimming != .PreserveWhitespaces)
                            {

                                // This text_part is independent from the rest and can be yelded later
                                // Let's produce the elements parsed until now
                                if (self.root.list.removeLast()) {
                                    const node = self.root.list.finish();

                                    self.epoch_arena.nextEpoch();
                                    const new_arena = self.epoch_arena.allocator();

                                    var root = try Level.create(new_arena, self.root.delimiters);
                                    self.root = root;
                                    self.current_level = root;

                                    // Adding it again for the next iteration,
                                    try self.current_level.addNode(new_arena, static_text_part.?.text_part);
                                    return node;
                                }
                            }
                        }
                    },

                    .section => {
                        try self.text_scanner.beginBookmark(self.gpa);
                        self.current_level = try self.current_level.nextLevel(arena);
                    },
                    .inverted_section,
                    .parent,
                    .block,
                    => {
                        self.current_level = try self.current_level.nextLevel(arena);
                    },

                    .close_section => {
                        const ret = self.current_level.endLevel() catch |err| {
                            return self.abort(err, text_part);
                        };

                        self.current_level = ret.level;
                        if (allow_lambdas and ret.parent_node.text_part.part_type == .section) {
                            if (try self.text_scanner.endBookmark(self.gpa)) |bookmark| {
                                ret.parent_node.inner_text = bookmark;
                            }
                        }

                        // Restore parent delimiters

                        self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                            return self.abort(err, text_part);
                        };
                    },

                    else => {},
                }
            }

            if (self.current_level != self.root) {
                return self.abort(ParseError.UnexpectedEof, null);
            }

            if (static_text_part) |static_text| {
                if (self.current_level.current_node) |last_node| {
                    static_text.trimLast(last_node);
                }
            }

            const node = self.root.list.finish();
            self.epoch_arena.nextEpoch();
            return node;
        }

        fn abort(self: *Self, err: ParseError, text_part: ?*const TextPart) AbortError {
            self.last_error = ParseErrorDetail{
                .parse_error = err,
                .lin = if (text_part) |p| p.lin else 0,
                .col = if (text_part) |p| p.col else 0,
            };

            return AbortError.ParserAbortedError;
        }
    };
}

const StreamedParser = Parser(.{ .source = .{ .String = .{} }, .output = .Render });

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
        try testing.expectEqual(PartType.comments, siblings.next().?.text_part.part_type);
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
        try testing.expectEqual(PartType.static_text, node_0.text_part.part_type);
        try testing.expectEqualStrings("  Hello\n", node_0.text_part.content);

        const node_1 = siblings.next().?;
        try testing.expectEqual(PartType.section, node_1.text_part.part_type);

        if (node_1.link.child != null) {
            var children = node_1.children();
            try testing.expectEqual(@as(usize, 8), children.len());

            const section_0 = children.next().?;
            try testing.expectEqual(PartType.static_text, section_0.text_part.part_type);

            const section_1 = children.next().?;
            try testing.expectEqual(PartType.interpolation, section_1.text_part.part_type);
            try testing.expectEqualStrings("name", section_1.text_part.content);

            const section_2 = children.next().?;
            try testing.expectEqual(PartType.static_text, section_2.text_part.part_type);

            const section_3 = children.next().?;
            try testing.expectEqual(PartType.no_escape, section_3.text_part.part_type);
            try testing.expectEqualStrings("comments", section_3.text_part.content);

            const section_4 = children.next().?;
            try testing.expectEqual(PartType.static_text, section_4.text_part.part_type);
            try testing.expectEqualStrings("\n", section_4.text_part.content);

            const section_5 = children.next().?;
            try testing.expectEqual(PartType.inverted_section, section_5.text_part.part_type);

            const section_6 = children.next().?;
            try testing.expectEqual(PartType.static_text, section_6.text_part.part_type);
            try testing.expectEqualStrings("\n", section_6.text_part.content);

            const section_7 = children.next().?;
            try testing.expectEqual(PartType.close_section, section_7.text_part.part_type);
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
        try testing.expectEqual(PartType.static_text, node_0.text_part.part_type);
        try testing.expectEqualStrings("World", node_0.text_part.content);
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
        try testing.expectEqual(PartType.static_text, node_0.text_part.part_type);
        try testing.expect(node_0.text_part.content.len == 0);

        const node_1 = siblings.next().?;
        try testing.expectEqual(PartType.comments, node_1.text_part.part_type);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 1), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(PartType.static_text, node_0.text_part.part_type);
        try testing.expectEqualStrings("Hello", node_0.text_part.content);
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
        try testing.expectEqual(PartType.delimiters, node_0.text_part.part_type);
        try testing.expectEqualStrings("[ ]", node_0.text_part.content);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |node| {
        var siblings = node.siblings();
        defer StreamedParser.Node.unRefMany(allocator, &siblings);

        try testing.expectEqual(@as(usize, 2), siblings.len());

        const node_0 = siblings.next().?;
        try testing.expectEqual(PartType.static_text, node_0.text_part.part_type);
        try testing.expect(node_0.text_part.content.len == 0);

        const node_1 = siblings.next().?;
        try testing.expectEqual(PartType.interpolation, node_1.text_part.part_type);
        try testing.expectEqualStrings("interpolation", node_1.text_part.content);
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
        try testing.expectEqual(PartType.static_text, node_0.?.text_part.part_type);
        try testing.expectEqualStrings("missing}}", node_0.?.text_part.content);
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

    var list = std.ArrayListUnmanaged(Element){};
    defer list.deinit(testing.allocator);

    _ = parser.createElements(&list, null, &siblings) catch |e| {
        if (parser.last_error) |err| {
            return err;
        } else {
            return e;
        }
    };

    try testing.expect(false);
    unreachable;
}
