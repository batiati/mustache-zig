/// Seeks a string for a events such as '{{', '}}' or a EOF
/// It is the first stage of the parsing process, the TextScanner produces TextBlocks to be parsed as mustache elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const ParseError = mustache.ParseError;
const TemplateOptions = mustache.options.TemplateOptions;
const TemplateLoadMode = mustache.options.TemplateLoadMode;

const ref_counter = @import("ref_counter.zig");

const parsing = @import("parsing.zig");
const PartType = parsing.PartType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const IndexBookmark = parsing.IndexBookmark;

pub fn TextScannerType(comptime Node: type, comptime options: TemplateOptions) type {
    const RefCounter = ref_counter.RefCounter(options);
    const TrimmingIndex = parsing.TrimmingIndex(options);
    const FileReader = parsing.FileReaderType(options);

    const allow_lambdas = options.features.lambdas == .enabled;

    return struct {
        const TextScanner = @This();

        const TextPart = Node.TextPart;
        const Trimmer = parsing.TrimmerType(TextScanner, TrimmingIndex);

        const Pos = struct {
            lin: u32 = 1,
            col: u32 = 1,
        };

        const State = union(enum) {
            matching_open: DelimiterIndex,
            matching_close: MatchingCloseState,
            produce_open: void,
            produce_close: PartType,
            eos: void,

            const DelimiterIndex = u16;
            const MatchingCloseState = struct {
                delimiter_index: DelimiterIndex = 0,
                part_type: PartType,
            };
        };

        content: []const u8,
        index: u32 = 0,
        block_index: u32 = 0,
        state: State = .{ .matching_open = 0 },
        start_pos: Pos = .{},
        current_pos: Pos = .{},
        delimiter_max_size: u32 = 0,
        delimiters: Delimiters = undefined,
        nodes: *const Node.List = undefined,

        file: if (options.source == .file) struct {
            reader: FileReader,
            ref_counter: RefCounter = .{},
            preserve_bookmark: ?u32 = null,
        } else void = undefined,

        bookmark: if (allow_lambdas) struct {
            node_index: ?u32 = null,
            last_starting_mark: u32 = 0,
        } else void = if (allow_lambdas) .{} else {},

        pub const ComptimeCounter = struct {
            /// Quantity of nodes present on the template text
            nodes: usize = 0,

            /// Max path lengh present on the template text
            path: usize = 0,

            pub fn count() @This() {
                comptime {
                    const comptime_loaded = switch (options.load_mode) {
                        .comptime_loaded => |payload| payload,
                        .runtime_loaded => @compileError("Cannot count a runtime loaded template"),
                    };

                    @setEvalBranchQuota(999999);
                    const allocator: Allocator = undefined;
                    var scanner = TextScanner.init(comptime_loaded.template_text) catch unreachable;
                    scanner.setDelimiters(comptime_loaded.default_delimiters) catch {
                        // TODO
                        unreachable;
                    };

                    var ret: @This() = .{};
                    while (scanner.next(allocator) catch unreachable) |*part| {
                        ret.nodes += 1;

                        const len: usize = switch (part.part_type) {
                            .interpolation,
                            .section,
                            .inverted_section,
                            .unescaped_interpolation,
                            .triple_mustache,
                            => std.mem.count(u8, part.content.slice, ".") + 1,
                            .delimiters => {
                                const delimiter = part.parseDelimiters() orelse continue;
                                scanner.setDelimiters(delimiter) catch {
                                    // TODO
                                    unreachable;
                                };

                                continue;
                            },
                            else => continue,
                        };

                        if (len > ret.path) ret.path = len;
                    }

                    return ret;
                }
            }
        };

        /// Should be the template content if source == .string
        /// or the absolute path if source == .File
        pub fn init(template: []const u8) if (options.source == .string)
            error{}!TextScanner
        else
            FileReader.OpenError!TextScanner {
            return switch (options.source) {
                .string => TextScanner{
                    .content = template,
                },
                .file => TextScanner{
                    .content = &.{},
                    .file = .{
                        .reader = try FileReader.init(template),
                    },
                },
            };
        }

        pub fn deinit(self: *TextScanner, allocator: Allocator) void {
            if (comptime options.source == .file) {
                self.file.ref_counter.unRef(allocator);
                self.file.reader.deinit();
            }
        }

        pub fn setDelimiters(self: *TextScanner, delimiters: Delimiters) ParseError!void {
            if (delimiters.starting_delimiter.len == 0) return ParseError.InvalidDelimiters;
            if (delimiters.ending_delimiter.len == 0) return ParseError.InvalidDelimiters;

            self.delimiter_max_size = @as(u32, @intCast(@max(delimiters.starting_delimiter.len, delimiters.ending_delimiter.len))) + 1;
            self.delimiters = delimiters;
        }

        fn requestContent(self: *TextScanner, allocator: Allocator) !void {
            if (comptime options.source == .file) {
                if (!self.file.reader.eof) {
                    // Requesting a new buffer must preserve some parts of the current slice that are still needed
                    const adjust: struct { off_set: u32, preserve: ?u32 } = adjust: {

                        // block_index: initial index of the current TextBlock, the minimum part needed
                        // bookmark.last_starting_mark: index of the last starting mark '{{', used to determine the inner_text between two tags
                        const last_index = if (self.bookmark.node_index == null) self.block_index else @min(self.block_index, self.bookmark.last_starting_mark);

                        if (self.file.preserve_bookmark) |preserve| {

                            // Only when reading from Stream
                            // stream.preserve_bookmark: is the index of the pending bookmark

                            if (preserve < last_index) {
                                break :adjust .{
                                    .off_set = preserve,
                                    .preserve = 0,
                                };
                            } else {
                                break :adjust .{
                                    .off_set = last_index,
                                    .preserve = preserve - last_index,
                                };
                            }
                        } else {
                            break :adjust .{
                                .off_set = last_index,
                                .preserve = null,
                            };
                        }
                    };

                    const prepend = self.content[adjust.off_set..];

                    const read = try self.file.reader.read(allocator, prepend);
                    errdefer read.ref_counter.unRef(allocator);

                    self.file.ref_counter.unRef(allocator);
                    self.file.ref_counter = read.ref_counter;

                    self.content = read.slice;
                    self.index -= adjust.off_set;
                    self.block_index -= adjust.off_set;

                    if (allow_lambdas) {
                        if (self.bookmark.node_index != null) {
                            self.adjustBookmarkOffset(self.bookmark.node_index, adjust.off_set);
                            self.bookmark.last_starting_mark -= adjust.off_set;
                        }

                        self.file.preserve_bookmark = adjust.preserve;
                    }
                }
            }
        }

        pub fn next(self: *TextScanner, allocator: Allocator) !?TextPart {
            if (self.state == .eos) return null;

            self.index = self.block_index;
            var trimmer = Trimmer.init(self);
            while (true) : (self.index += 1) {
                if (comptime options.source == .file) {
                    if (!self.file.reader.eof) {
                        // Request a new slice if near to the end
                        const look_ahead = self.index + self.delimiter_max_size + 1;
                        if (look_ahead >= self.content.len) {
                            try self.requestContent(allocator);
                        }
                    }
                }

                if (self.index >= self.content.len) break;

                const char = self.content[self.index];

                switch (self.state) {
                    .matching_open => |delimiter_index| {
                        const delimiter_char = self.delimiters.starting_delimiter[delimiter_index];
                        if (char == delimiter_char) {
                            const next_index = delimiter_index + 1;
                            if (self.delimiters.starting_delimiter.len == next_index) {
                                self.state = .produce_open;
                            } else {
                                self.state.matching_open = next_index;
                            }
                        } else {
                            self.state.matching_open = 0;
                            trimmer.move();
                        }

                        self.moveLineCounter(char);
                    },
                    .matching_close => |*close_state| {
                        const delimiter_char = self.delimiters.ending_delimiter[close_state.delimiter_index];
                        if (char == delimiter_char) {
                            const next_index = close_state.delimiter_index + 1;

                            if (self.delimiters.ending_delimiter.len == next_index) {
                                self.state = .{ .produce_close = close_state.part_type };
                            } else {
                                close_state.delimiter_index = next_index;
                            }
                        } else {
                            close_state.delimiter_index = 0;
                        }

                        self.moveLineCounter(char);
                    },
                    .produce_open => {
                        return self.produceOpen(trimmer, char) orelse continue;
                    },
                    .produce_close => {
                        return self.produceClose(trimmer, char);
                    },
                    .eos => return null,
                }
            }

            return self.produceEos(trimmer);
        }

        inline fn moveLineCounter(self: *TextScanner, char: u8) void {
            if (char == '\n') {
                self.current_pos.lin += 1;
                self.current_pos.col = 1;
            } else {
                self.current_pos.col += 1;
            }
        }

        fn produceOpen(self: *TextScanner, trimmer: Trimmer, char: u8) ?TextPart {
            const skip_current = switch (char) {
                @intFromEnum(PartType.comments),
                @intFromEnum(PartType.section),
                @intFromEnum(PartType.inverted_section),
                @intFromEnum(PartType.close_section),
                @intFromEnum(PartType.partial),
                @intFromEnum(PartType.parent),
                @intFromEnum(PartType.block),
                @intFromEnum(PartType.unescaped_interpolation),
                @intFromEnum(PartType.delimiters),
                @intFromEnum(PartType.triple_mustache),
                => true,
                else => false,
            };

            const delimiter_len = @as(u32, @intCast(self.delimiters.starting_delimiter.len));

            defer {
                self.start_pos = .{
                    .lin = self.current_pos.lin,
                    .col = self.current_pos.col - delimiter_len,
                };

                if (skip_current) {

                    // Skips the current char on the next iteration if it is part of the tag, like '#' is part of '{{#'
                    self.block_index = self.index + 1;
                    self.moveLineCounter(char);

                    // Sets the next state
                    self.state = .{
                        .matching_close = .{
                            .delimiter_index = 0,
                            .part_type = @as(PartType, @enumFromInt(char)),
                        },
                    };
                } else {

                    // If the current char is not part of the tag, it must be processed again on the next iteration
                    self.block_index = self.index;

                    // Sets the next state
                    self.state = .{
                        .matching_close = .{
                            .delimiter_index = 0,
                            .part_type = .interpolation,
                        },
                    };
                }
            }

            const last_pos = self.index - delimiter_len;
            if (allow_lambdas) self.bookmark.last_starting_mark = last_pos;
            const tail = self.content[self.block_index..last_pos];

            return if (tail.len > 0) TextPart{
                .part_type = .static_text,
                .is_stand_alone = PartType.canBeStandAlone(.static_text),
                .content = .{
                    .slice = tail,
                    .ref_counter = if (options.source == .file) self.file.ref_counter.ref() else .{},
                },
                .source = .{
                    .lin = self.start_pos.lin,
                    .col = self.start_pos.col,
                },
                .trimming = .{
                    .left = trimmer.getLeftTrimmingIndex(),
                    .right = trimmer.getRightTrimmingIndex(),
                },
            } else null;
        }

        fn produceClose(self: *TextScanner, trimmer: Trimmer, char: u8) TextPart {
            const triple_mustache_close = '}';
            const Mark = struct { block_index: u32, skip_current: bool };

            const mark: Mark = mark: {
                switch (char) {
                    triple_mustache_close => {
                        defer self.block_index = self.index + 1;
                        break :mark .{ .block_index = self.block_index, .skip_current = true };
                    },
                    else => {
                        defer self.block_index = self.index;
                        break :mark .{ .block_index = self.block_index, .skip_current = false };
                    },
                }
            };

            defer {
                self.state = .{ .matching_open = 0 };

                if (mark.skip_current) self.moveLineCounter(char);
                self.start_pos = .{
                    .lin = self.current_pos.lin,
                    .col = self.current_pos.col,
                };
            }

            const last_pos = self.index - self.delimiters.ending_delimiter.len;
            const tail = self.content[mark.block_index..last_pos];

            return TextPart{
                .part_type = self.state.produce_close,
                .is_stand_alone = PartType.canBeStandAlone(self.state.produce_close),
                .content = .{
                    .slice = tail,
                    .ref_counter = if (options.source == .file) self.file.ref_counter.ref() else .{},
                },
                .source = .{
                    .lin = self.start_pos.lin,
                    .col = self.start_pos.col,
                },
                .trimming = .{
                    .left = trimmer.getLeftTrimmingIndex(),
                    .right = trimmer.getRightTrimmingIndex(),
                },
            };
        }

        fn produceEos(self: *TextScanner, trimmer: Trimmer) ?TextPart {
            defer self.state = .eos;

            switch (self.state) {
                .produce_close => |part_type| {
                    const last_pos = self.content.len - self.delimiters.ending_delimiter.len;
                    const tail = self.content[self.block_index..last_pos];

                    return TextPart{
                        .part_type = part_type,
                        .is_stand_alone = part_type.canBeStandAlone(),
                        .content = .{
                            .slice = tail,
                            .ref_counter = if (options.source == .file) self.file.ref_counter.ref() else .{},
                        },
                        .source = .{
                            .lin = self.start_pos.lin,
                            .col = self.start_pos.col,
                        },
                        .trimming = .{
                            .left = trimmer.getLeftTrimmingIndex(),
                            .right = trimmer.getRightTrimmingIndex(),
                        },
                    };
                },
                else => {
                    const tail = self.content[self.block_index..];

                    return if (tail.len > 0)
                        TextPart{
                            .part_type = .static_text,
                            .is_stand_alone = PartType.canBeStandAlone(.static_text),
                            .content = .{
                                .slice = tail,
                                .ref_counter = if (options.source == .file) self.file.ref_counter.ref() else .{},
                            },
                            .source = .{
                                .lin = self.start_pos.lin,
                                .col = self.start_pos.col,
                            },
                            .trimming = .{
                                .left = trimmer.getLeftTrimmingIndex(),
                                .right = trimmer.getRightTrimmingIndex(),
                            },
                        }
                    else
                        null;
                },
            }
        }

        pub fn beginBookmark(self: *TextScanner, node: *Node) Allocator.Error!void {
            if (allow_lambdas) {
                assert(node.inner_text.bookmark == null);
                node.inner_text.bookmark = IndexBookmark{
                    .prev_node_index = self.bookmark.node_index,
                    .text_index = self.index,
                };

                self.bookmark.node_index = node.index;
                if (options.source == .file) {
                    if (self.file.preserve_bookmark) |preserve| {
                        assert(preserve <= self.index);
                    } else {
                        self.file.preserve_bookmark = self.index;
                    }
                }
            }
        }

        pub fn endBookmark(self: *TextScanner, list: *Node.List) Allocator.Error!?[]const u8 {
            if (allow_lambdas) {
                if (self.bookmark.node_index) |node_index| {
                    const current = &list.items[node_index];
                    const bookmark = if (current.inner_text.bookmark) |*value| value else unreachable;

                    defer {
                        self.bookmark.node_index = bookmark.prev_node_index;
                        if (options.source == .file and bookmark.prev_node_index == null) {
                            self.file.preserve_bookmark = null;
                        }
                    }

                    assert(bookmark.text_index < self.content.len);
                    assert(bookmark.text_index <= self.bookmark.last_starting_mark);
                    assert(self.bookmark.last_starting_mark < self.content.len);

                    return self.content[bookmark.text_index..self.bookmark.last_starting_mark];
                }
            }

            return null;
        }

        fn adjustBookmarkOffset(self: *TextScanner, node_index: ?u32, off_set: u32) void {
            if (allow_lambdas) {
                if (node_index) |index| {
                    var current = &self.nodes.items[index];
                    var bookmark = if (current.inner_text.bookmark) |*value| value else unreachable;
                    assert(bookmark.text_index >= off_set);
                    bookmark.text_index -= off_set;
                    self.adjustBookmarkOffset(bookmark.prev_node_index, off_set);
                }
            }
        }
    };
}

const testing_options = TemplateOptions{
    .source = .{ .string = .{} },
    .output = .render,
};
const TestingNode = parsing.NodeType(testing_options);
const TestingTextScanner = parsing.TextScannerType(TestingNode, testing_options);
const TestingTrimmingIndex = parsing.TrimmingIndex(testing_options);

test "basic tests" {
    const content =
        \\Hello{{tag1}}
        \\World{{{ tag2 }}}Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TestingTextScanner.init(content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try expectTag(.static_text, "Hello", part_1, 1, 1);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_2, 1, 6);
    defer part_2.?.unRef(allocator);

    var part_3 = try reader.next(allocator);

    try expectTag(.static_text, "\nWorld", part_3, 1, 14);
    defer part_3.?.unRef(allocator);

    var part_4 = try reader.next(allocator);
    try expectTag(.triple_mustache, " tag2 ", part_4, 2, 6);
    defer part_4.?.unRef(allocator);

    var part_5 = try reader.next(allocator);
    try expectTag(.static_text, "Until eof", part_5, 2, 18);
    defer part_5.?.unRef(allocator);

    const part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "custom tags" {
    const content =
        \\Hello[tag1]
        \\World[ tag2 ]Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TestingTextScanner.init(content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try expectTag(.static_text, "Hello", part_1, 1, 1);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_2, 1, 6);
    defer part_2.?.unRef(allocator);

    var part_3 = try reader.next(allocator);
    try expectTag(.static_text, "\nWorld", part_3, 1, 12);
    defer part_3.?.unRef(allocator);

    var part_4 = try reader.next(allocator);
    try expectTag(.interpolation, " tag2 ", part_4, 2, 6);
    defer part_4.?.unRef(allocator);

    var part_5 = try reader.next(allocator);
    try expectTag(.static_text, "Until eof", part_5, 2, 14);
    defer part_5.?.unRef(allocator);

    const part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "EOF" {
    const content = "{{tag1}}";

    const allocator = testing.allocator;

    var reader = try TestingTextScanner.init(content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_1, 1, 1);
    defer part_1.?.unRef(allocator);

    const part_2 = try reader.next(allocator);
    try testing.expect(part_2 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    const allocator = testing.allocator;

    var reader = try TestingTextScanner.init(content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_1, 1, 1);
    defer part_1.?.unRef(allocator);

    const part_2 = try reader.next(allocator);
    try testing.expect(part_2 == null);
}

test "bookmarks" {

    //                        1         2         3         4         5         6         7         8
    //               1234567890123456789012345678901234567890123456789012345678901234567890123456789012345
    //               ↓            ↓             ↓            ↓       ↓            ↓           ↓
    const content = "{{#section1}}begin_content1{{#section2}}content2{{/section2}}end_content1{{/section1}}";
    const allocator = testing.allocator;

    var nodes: TestingNode.List = .{};
    defer nodes.deinit(allocator);

    var reader = try TestingTextScanner.init(content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var token_1 = try reader.next(allocator);
    try expectTag(.section, "section1", token_1, 1, 1);
    defer token_1.?.unRef(allocator);

    try nodes.append(allocator, TestingNode{ .index = 0, .identifier = undefined, .text_part = token_1.? });
    try reader.beginBookmark(&nodes.items[0]);

    var token_2 = try reader.next(allocator);
    try expectTag(.static_text, "begin_content1", token_2, 1, 14);
    defer token_2.?.unRef(allocator);

    var token_3 = try reader.next(allocator);
    try expectTag(.section, "section2", token_3, 1, 28);
    defer token_3.?.unRef(allocator);

    try nodes.append(allocator, TestingNode{ .index = 1, .identifier = undefined, .text_part = token_3.? });
    try reader.beginBookmark(&nodes.items[1]);

    var token_4 = try reader.next(allocator);
    try expectTag(.static_text, "content2", token_4, 1, 41);
    defer token_4.?.unRef(allocator);

    var token_5 = try reader.next(allocator);
    try expectTag(.close_section, "section2", token_5, 1, 49);
    defer token_5.?.unRef(allocator);

    if (try reader.endBookmark(&nodes)) |bookmark_1| {
        try testing.expectEqualStrings("content2", bookmark_1);
    } else {
        try testing.expect(false);
    }

    var token_6 = try reader.next(allocator);
    try expectTag(.static_text, "end_content1", token_6, 1, 62);
    defer token_6.?.unRef(allocator);

    var token_7 = try reader.next(allocator);
    try expectTag(.close_section, "section1", token_7, 1, 74);
    defer token_7.?.unRef(allocator);

    if (try reader.endBookmark(&nodes)) |bookmark_2| {
        try testing.expectEqualStrings("begin_content1{{#section2}}content2{{/section2}}end_content1", bookmark_2);
    } else {
        try testing.expect(false);
    }

    const part_8 = try reader.next(allocator);
    try testing.expect(part_8 == null);
}

fn expectTag(part_type: PartType, content: []const u8, value: anytype, lin: u32, col: u32) !void {
    if (value) |part| {
        try testing.expectEqual(part_type, part.part_type);
        try testing.expectEqualStrings(content, part.content.slice);
        try testing.expectEqual(lin, part.source.lin);
        try testing.expectEqual(col, part.source.col);
    } else {
        try testing.expect(false);
    }
}
