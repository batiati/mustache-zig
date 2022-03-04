const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.template.TemplateOptions;

const Template = mustache.template.Template;
const Element = mustache.template.Element;
const Interpolation = mustache.template.Interpolation;
const Section = mustache.template.Section;
const Partial = mustache.template.Partial;
const Parent = mustache.template.Parent;
const Block = mustache.template.Block;
const LastError = mustache.template.LastError;

const ParseErrors = mustache.template.ParseErrors;

const mem = @import("../mem.zig");
const EpochArena = mem.EpochArena;
const RefCounter = mem.RefCounter;
const RefCounterHolder = mem.RefCounterHolder;

const assert = std.debug.assert;
const testing = std.testing;

pub const Level = @import("Level.zig");
pub const Node = @import("Node.zig");
pub const TextBlock = @import("TextBlock.zig");
pub const TextScanner = @import("text_scanner.zig").TextScanner;
pub const TextSource = @import("text_scanner.zig").TextSource;
pub const Trimmer = @import("trimmer.zig").Trimmer;
pub const FileReader = @import("FileReader.zig");

pub const Delimiters = struct {
    pub const DefaultStartingDelimiter = "{{";
    pub const DefaultEndingDelimiter = "}}";
    pub const NoScapeStartingDelimiter = "{{{";
    pub const NoScapeEndingDelimiter = "}}}";

    starting_delimiter: []const u8 = DefaultStartingDelimiter,
    ending_delimiter: []const u8 = DefaultEndingDelimiter,
};

pub const tokens = struct {
    pub const Comments = '!';
    pub const Section = '#';
    pub const InvertedSection = '^';
    pub const CloseSection = '/';
    pub const Partial = '>';
    pub const Parent = '<';
    pub const Block = '$';
    pub const NoEscape = '&';
    pub const Delimiters = '=';
};

pub const BlockType = enum {
    StaticText,
    Comment,
    Delimiters,
    Interpolation,
    NoScapeInterpolation,
    Section,
    InvertedSection,
    CloseSection,
    Partial,
    Parent,
    Block,

    pub inline fn canBeStandAlone(self: BlockType) bool {
        return switch (self) {
            .StaticText,
            .Interpolation,
            .NoScapeInterpolation,
            => false,
            else => true,
        };
    }

    pub inline fn ignoreStaticText(self: BlockType) bool {
        return switch (self) {
            .Parent => true,
            else => false,
        };
    }
};

pub const MarkType = enum {

    /// A starting tag mark, such '{{', '{{{' or any configured delimiter
    Starting,

    /// A ending tag mark, such '}}', '}}}' or any configured delimiter
    Ending,

    /// The same tag mark is used both for staring and ending, such '%' or '|'
    Both,
};

pub const DelimiterType = enum {

    /// Delimiter is '{{', '}}', or any configured delimiter
    Regular,

    /// Delimiter is a non-scaped (aka triple mustache) delimiter such '{{{' or '}}}' 
    NoScapeDelimiter,
};

pub const Mark = struct {
    mark_type: MarkType,
    delimiter_type: DelimiterType,
    delimiter: []const u8,
};

pub const Event = union(enum) {
    Mark: Mark,
    Eof,
};

pub const TrimmingIndex = union(enum) {
    PreserveWhitespaces,
    AllowTrimming: struct {
        index: u32,
        stand_alone: bool,
    },
    Trimmed,
};

pub const ParserOptions = struct {
    delimiters: Delimiters,
    source: TextSource,
    owns_string: bool,
    streamed: bool,
};

pub fn Parser(comptime parser_options: ParserOptions) type {
    return struct {
        const State = enum {
            WaitingStaringTag,
            WaitingEndingTag,
        };

        const ProcessingErrors = Allocator.Error || if (options.source == .File) std.fs.File.ReadError || std.fs.File.OpenError else error{};

        pub const Errors = (ParseErrors || ProcessingErrors);

        pub const options = struct {
            pub const source = parser_options.source;
            pub const streamed = parser_options.streamed;
            pub const owns_string = parser_options.owns_string;
        };

        pub const ParseResult = union(enum) {
            Error: LastError,
            Nodes: []*Node,
            Done,
        };

        const Self = @This();

        /// General purpose allocator
        gpa: Allocator,

        /// When in streamed mode, this combines two arenas, allowing to free memory each time the parser produces
        /// When the "nextEpoch" function is called, the current arena is reserved and a new one is initialized for use.
        arena: if (options.streamed) EpochArena else ArenaAllocator,

        /// Text scanner instance, shoud not be accessed directly
        text_scanner: TextScanner(options.source),

        /// Parser state, shoud not be accessed directly
        state: State,

        /// Root level, holding all nested nodes produced, should not be accessed direcly
        root: *Level,

        /// Current level, holding the current tag being processed
        current_level: *Level,

        /// Stores the last error ocurred parsing the content
        last_error: ?LastError = null,

        /// Used when the field "options.owns_string = false"
        /// Holds a ref_counter to the read buffer for all produced elements
        ref_counter_holder: if (options.owns_string) void else RefCounterHolder = if (options.owns_string) {} else RefCounterHolder{},

        pub fn init(gpa: Allocator, template: []const u8) if (options.source == .String) Allocator.Error!Self else FileReader.Errors!Self {
            const Arena = if (options.streamed) EpochArena else ArenaAllocator;
            var arena = Arena.init(gpa);
            errdefer arena.deinit();

            var root = try Level.init(arena.allocator(), parser_options.delimiters);

            return Self{
                .gpa = gpa,
                .arena = arena,
                .text_scanner = try TextScanner(options.source).init(gpa, template),
                .state = .WaitingStaringTag,
                .root = root,
                .current_level = root,
            };
        }

        pub fn deinit(self: *Self) void {
            self.text_scanner.deinit(self.gpa);
            self.arena.deinit();
            if (!options.owns_string) self.ref_counter_holder.free(self.gpa);
        }

        pub fn parse(self: *Self) ProcessingErrors!ParseResult {
            var ret = self.parseTree() catch |err| {
                return try self.fromError(err);
            };

            if (ret) |nodes| {
                return ParseResult{ .Nodes = nodes };
            } else {
                return ParseResult.Done;
            }
        }

        fn fromError(self: *Self, err: Errors) ProcessingErrors!ParseResult {
            switch (err) {
                Errors.StartingDelimiterMismatch,
                Errors.EndingDelimiterMismatch,
                Errors.UnexpectedEof,
                Errors.UnexpectedCloseSection,
                Errors.InvalidDelimiters,
                Errors.InvalidIdentifier,
                Errors.ClosingTagMismatch,
                => |parse_err| return ParseResult{
                    .Error = self.last_error orelse .{ .error_code = parse_err },
                },
                else => |any| return any,
            }
        }

        inline fn dupe(self: *Self, ref_counter: RefCounter, slice: []const u8) Allocator.Error![]const u8 {
            if (options.owns_string) {
                return try self.gpa.dupe(u8, slice);
            } else {
                try self.ref_counter_holder.add(self.gpa, ref_counter);
                return slice;
            }
        }

        pub fn createElements(self: *Self, parent_key: ?[]const u8, nodes: []*Node) Errors![]Element {
            var list = try std.ArrayListUnmanaged(Element).initCapacity(self.gpa, nodes.len);
            errdefer list.deinit(self.gpa);
            defer Node.deinitMany(self.gpa, nodes);

            for (nodes) |node| {
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
                            const key = try self.dupe(node.text_block.ref_counter, try self.parseIdentificator(&node.text_block));
                            errdefer if (options.owns_string) self.gpa.free(key);

                            const content = if (node.children) |children| try self.createElements(key, children) else null;
                            errdefer if (content) |content_value| Element.freeMany(self.gpa, options.owns_string, content_value);

                            const indentation = if (node.getIndentation()) |node_indentation| try self.dupe(node.text_block.ref_counter, node_indentation) else null;
                            errdefer if (options.owns_string) if (indentation) |indentation_value| self.gpa.free(indentation_value);

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

        fn parseIdentificator(self: *Self, text_block: *const TextBlock) ParseErrors![]const u8 {
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

        fn parseTree(self: *Self) Errors!?[]*Node {
            if (self.text_scanner.delimiters_count == 0) {
                self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
                    return self.setLastError(err, null, null);
                };
            }

            const arena = self.arena.allocator();
            var static_text_block: ?*Node = null;

            while (try self.text_scanner.next(self.gpa)) |*text_block| {
                errdefer text_block.deinit(self.gpa);

                var block_type = (try self.matchBlockType(text_block)) orelse {
                    text_block.deinit(self.gpa);
                    continue;
                };

                // Befone adding,
                switch (block_type) {
                    .StaticText => {
                        if (self.current_level.current_node) |current_node| {
                            if (current_node.block_type.ignoreStaticText()) {
                                text_block.deinit(self.gpa);
                                continue;
                            }
                        }
                    },
                    .Delimiters => {

                        //Apply the new delimiters to the reader immediately
                        const new_delimiters = try self.parseDelimiters(text_block);

                        self.text_scanner.setDelimiters(new_delimiters) catch |err| {
                            return self.setLastError(err, text_block, null);
                        };

                        self.current_level.delimiters = new_delimiters;
                        text_block.deinit(self.gpa);
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

                        // When running on streamed mode,
                        // A stand-alone line in the root level indicates that the previous produced nodes can be rendered
                        if (options.streamed) {
                            if (self.current_level == self.root and self.root.list.items.len > 1) {
                                if (static_text_block.?.text_block.left_trimming != .PreserveWhitespaces) {

                                    // This text_block is independent from the rest and can be yelded later
                                    // Let's produce the elements parsed until now
                                    _ = self.root.list.pop();

                                    const nodes = self.root.list.toOwnedSlice(arena);

                                    self.arena.nextEpoch();
                                    const new_arena = self.arena.allocator();

                                    var root = try Level.init(new_arena, self.root.delimiters);
                                    self.root = root;
                                    self.current_level = root;

                                    // Adding it again for the next iteration,
                                    try self.current_level.addNode(new_arena, block_type, static_text_block.?.text_block);
                                    return nodes;
                                }
                            }
                        }
                    },

                    .Section,
                    .InvertedSection,
                    .Parent,
                    .Block,
                    => {
                        self.current_level = try self.current_level.nextLevel(arena);
                    },

                    .CloseSection => {
                        self.current_level = self.current_level.endLevel(arena) catch |err| {
                            return self.setLastError(err, text_block, null);
                        };

                        // Restore parent delimiters

                        self.text_scanner.setDelimiters(self.current_level.delimiters) catch |err| {
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

            if (self.root.list.items.len == 0) {
                return null;
            } else {
                const nodes = self.root.list.toOwnedSlice(arena);

                if (options.streamed) {
                    self.arena.nextEpoch();
                }

                const new_arena = self.arena.allocator();
                var root = try Level.init(new_arena, self.root.delimiters);
                self.root = root;
                self.current_level = root;

                return nodes;
            }
        }

        fn setLastError(self: *Self, err: ParseErrors, text_block: ?*const TextBlock, detail: ?[]const u8) ParseErrors {
            self.last_error = LastError{
                .error_code = err,
                .row = if (text_block) |p| p.row else 0,
                .col = if (text_block) |p| p.col else 0,
                .detail = detail,
            };

            std.log.err(
                \\
                \\=================================
                \\Line {} col {}
                \\Err {}
                \\=================================
            , .{ self.last_error.?.row, self.last_error.?.col, self.last_error.?.error_code });

            return err;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

const StreamedParser = Parser(.{ .delimiters = .{}, .source = .String, .owns_string = true, .streamed = true });

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

    var parser = try StreamedParser.init(allocator, template_text);
    defer parser.deinit();

    var first_block = try testParseTree(&parser);

    // The parser produces only the minimun amount of tags that can be render at once
    if (first_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 1), nodes.len);
        try testing.expectEqual(BlockType.Comment, nodes[0].block_type);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);

    // Nested tags must be produced together
    if (second_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 2), nodes.len);

        try testing.expectEqual(BlockType.StaticText, nodes[0].block_type);
        try testing.expectEqualStrings("  Hello\n", nodes[0].text_block.tail.?);

        try testing.expectEqual(BlockType.Section, nodes[1].block_type);

        if (nodes[1].children) |section| {
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

    var third_block = try testParseTree(&parser);

    if (third_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 1), nodes.len);

        try testing.expectEqual(BlockType.StaticText, nodes[0].block_type);
        try testing.expectEqualStrings("World", nodes[0].text_block.tail.?);
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

    var parser = try StreamedParser.init(allocator, template_text);
    defer parser.deinit();

    var first_block = try testParseTree(&parser);

    // The parser produces only the minimun amount of tags that can be render at once
    if (first_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 2), nodes.len);

        try testing.expectEqual(BlockType.StaticText, nodes[0].block_type);
        try testing.expect(nodes[0].text_block.tail == null);

        try testing.expectEqual(BlockType.Comment, nodes[1].block_type);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 1), nodes.len);

        try testing.expectEqual(BlockType.StaticText, nodes[0].block_type);
        try testing.expectEqualStrings("Hello", nodes[0].text_block.tail.?);
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

    var parser = try StreamedParser.init(allocator, template_text);
    defer parser.deinit();

    // The parser produces only the minimun amount of tags that can be render at once

    var first_block = try testParseTree(&parser);
    if (first_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 1), nodes.len);

        try testing.expectEqual(BlockType.Delimiters, nodes[0].block_type);
        try testing.expectEqualStrings("[ ]", nodes[0].text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var second_block = try testParseTree(&parser);
    if (second_block) |nodes| {
        defer Node.deinitMany(allocator, nodes);

        try testing.expectEqual(@as(usize, 2), nodes.len);

        try testing.expectEqual(BlockType.StaticText, nodes[0].block_type);
        try testing.expect(nodes[0].text_block.tail == null);

        try testing.expectEqual(BlockType.Interpolation, nodes[1].block_type);
        try testing.expectEqualStrings("interpolation", nodes[1].text_block.tail.?);
    } else {
        try testing.expect(false);
    }

    var no_more = try testParseTree(&parser);
    try testing.expect(no_more == null);
}

fn testParseTree(parser: anytype) !?[]*Node {
    return parser.parseTree() catch |e| {
        if (parser.last_error) |err| {
            std.log.err("template {s} at row {}, col {};", .{ @errorName(err.error_code), err.row, err.col });
            try testing.expect(false);
        }

        return e;
    };
}
