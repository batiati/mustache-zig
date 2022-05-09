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

const memory = @import("memory.zig");

const parsing = @import("parsing.zig");
const PartType = parsing.PartType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const FileReader = parsing.FileReader;

pub fn TextScanner(comptime options: TemplateOptions) type {
    const RefCounter = memory.RefCounter(options);
    const RefCountedSlice = memory.RefCountedSlice(options);
    const TextPart = parsing.TextPart(options);
    const TrimmingIndex = parsing.TrimmingIndex(options);

    const allow_lambdas = options.features.lambdas == .Enabled;

    return struct {
        const Self = @This();
        const Trimmer = parsing.Trimmer(Self, TrimmingIndex);

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

        const Bookmark = struct {
            prev: ?*@This(),
            index: u32,
        };

        content: []const u8 = &.{},
        index: u32 = 0,
        block_index: u32 = 0,
        state: State = .{ .matching_open = 0 },
        lin: u32 = 1,
        col: u32 = 1,
        delimiter_max_size: u32 = 0,
        delimiters: Delimiters = undefined,

        stream: switch (options.source) {
            .Stream => struct {
                reader: *FileReader(options),
                ref_counter: RefCounter = .{},
                preserve_bookmark: ?u32 = null,
            },
            .String => void,
        } = undefined,

        bookmark: if (allow_lambdas) struct {
            stack: ?*Bookmark = null,
            last_starting_mark: u32 = 0,
        } else void = if (allow_lambdas) .{} else {},

        /// Should be the template content if source == .String
        /// or the absolute path if source == .File
        pub fn init(allocator: Allocator, template: []const u8) if (options.source == .String) Allocator.Error!Self else FileReader(options).Error!Self {
            switch (options.source) {
                .String => return Self{
                    .content = template,
                },
                .Stream => return Self{
                    .stream = .{
                        .reader = try FileReader(options).initFromPath(allocator, template),
                    },
                },
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (options.source == .Stream) {
                self.stream.ref_counter.free(allocator);
                self.stream.reader.deinit(allocator);

                freeBookmarks(allocator, self.bookmark.stack);
            }
        }

        pub fn setDelimiters(self: *Self, delimiters: Delimiters) ParseError!void {
            if (delimiters.starting_delimiter.len == 0) return ParseError.InvalidDelimiters;
            if (delimiters.ending_delimiter.len == 0) return ParseError.InvalidDelimiters;

            self.delimiter_max_size = @intCast(u32, std.math.max(delimiters.starting_delimiter.len, delimiters.ending_delimiter.len) + 1);
            self.delimiters = delimiters;
        }

        fn requestContent(self: *Self, allocator: Allocator) !void {
            if (options.source == .Stream) {
                if (!self.stream.reader.finished()) {

                    //
                    // Requesting a new buffer must preserve some parts of the current slice that are still needed
                    const adjust: struct { off_set: u32, preserve: ?u32 } = adjust: {

                        // block_index: initial index of the current TextBlock, the minimum part needed
                        // bookmark.last_starting_mark: index of the last starting mark '{{', used to determine the inner_text between two tags
                        const last_index = if (self.bookmark.stack == null) self.block_index else std.math.min(self.block_index, self.bookmark.last_starting_mark);

                        if (self.stream.preserve_bookmark) |preserve| {

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

                    const read = try self.stream.reader.read(allocator, prepend);
                    errdefer read.ref_counter.free(allocator);

                    self.stream.ref_counter.free(allocator);
                    self.stream.ref_counter = read.ref_counter;

                    self.content = read.content;
                    self.index -= adjust.off_set;
                    self.block_index -= adjust.off_set;

                    if (allow_lambdas) {
                        if (self.bookmark.stack != null) {
                            adjustBookmarkOffset(self.bookmark.stack, adjust.off_set);
                            self.bookmark.last_starting_mark -= adjust.off_set;
                        }

                        self.stream.preserve_bookmark = adjust.preserve;
                    }
                }
            }
        }

        pub fn next(self: *Self, allocator: Allocator) !?TextPart {
            if (self.state == .eos) return null;

            self.index = self.block_index;
            var trimmer = Trimmer.init(self);
            while (self.index < self.content.len or
                (options.source == .Stream and !self.stream.reader.finished())) : (self.index += 1)
            {
                if (options.source == .Stream) {
                    // Request a new slice if near to the end
                    const look_ahead = self.index + self.delimiter_max_size + 1;
                    if (look_ahead >= self.content.len) {
                        try self.requestContent(allocator);
                    }
                }

                const char = self.content[self.index];
                defer self.moveLineCounter(char);

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
                            trimmer.move();
                            self.state.matching_open = 0;
                        }
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

        inline fn moveLineCounter(self: *Self, char: u8) void {
            if (char == '\n') {
                self.lin += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
        }

        inline fn produceOpen(self: *Self, trimmer: Trimmer, char: u8) ?TextPart {
            const tail = tail: {
                switch (char) {
                    @enumToInt(PartType.comments),
                    @enumToInt(PartType.section),
                    @enumToInt(PartType.inverted_section),
                    @enumToInt(PartType.close_section),
                    @enumToInt(PartType.partial),
                    @enumToInt(PartType.parent),
                    @enumToInt(PartType.block),
                    @enumToInt(PartType.no_escape),
                    @enumToInt(PartType.delimiters),
                    @enumToInt(PartType.triple_mustache),
                    => {
                        defer {
                            self.block_index = self.index + 1;
                            self.state = .{
                                .matching_close = .{
                                    .delimiter_index = 0,
                                    .part_type = @intToEnum(PartType, char),
                                },
                            };
                        }

                        const last_pos = self.index - @intCast(u32, self.delimiters.starting_delimiter.len);
                        if (allow_lambdas) self.bookmark.last_starting_mark = last_pos;
                        break :tail self.content[self.block_index..last_pos];
                    },
                    else => {
                        defer {
                            self.block_index = self.index;
                            self.state = .{
                                .matching_close = .{
                                    .delimiter_index = 0,
                                    .part_type = .interpolation,
                                },
                            };
                        }

                        const last_pos = self.index - @intCast(u32, self.delimiters.starting_delimiter.len);
                        if (allow_lambdas) self.bookmark.last_starting_mark = last_pos;
                        break :tail self.content[self.block_index..last_pos];
                    },
                }
            };

            return if (tail.len > 0) TextPart{
                .content = tail,
                .part_type = .static_text,
                .lin = self.lin,
                .col = self.col,
                .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                .left_trimming = trimmer.getLeftTrimmingIndex(),
                .right_trimming = trimmer.getRightTrimmingIndex(),
            } else null;
        }

        inline fn produceClose(self: *Self, trimmer: Trimmer, char: u8) TextPart {
            const triple_mustache_close = '}';

            defer self.state = .{ .matching_open = 0 };
            const tail = tail: {
                switch (char) {
                    triple_mustache_close => {
                        defer self.block_index = self.index + 1;
                        const last_pos = self.index - self.delimiters.ending_delimiter.len;
                        break :tail self.content[self.block_index..last_pos];
                    },
                    else => {
                        defer self.block_index = self.index;
                        const last_pos = self.index - self.delimiters.ending_delimiter.len;
                        break :tail self.content[self.block_index..last_pos];
                    },
                }
            };

            return TextPart{
                .content = tail,
                .part_type = self.state.produce_close,
                .lin = self.lin,
                .col = self.col,
                .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                .left_trimming = trimmer.getLeftTrimmingIndex(),
                .right_trimming = trimmer.getRightTrimmingIndex(),
            };
        }

        inline fn produceEos(self: *Self, trimmer: Trimmer) ?TextPart {
            defer self.state = .eos;

            switch (self.state) {
                .produce_close => |part_type| {
                    const last_pos = self.content.len - self.delimiters.ending_delimiter.len;
                    const tail = self.content[self.block_index..last_pos];

                    return TextPart{
                        .content = tail,
                        .part_type = part_type,
                        .lin = self.lin,
                        .col = self.col,
                        .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                        .left_trimming = trimmer.getLeftTrimmingIndex(),
                        .right_trimming = trimmer.getRightTrimmingIndex(),
                    };
                },
                else => {
                    const tail = self.content[self.block_index..];

                    return if (tail.len > 0)
                        TextPart{
                            .content = tail,
                            .part_type = .static_text,
                            .lin = self.lin,
                            .col = self.col,
                            .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                            .left_trimming = trimmer.getLeftTrimmingIndex(),
                            .right_trimming = trimmer.getRightTrimmingIndex(),
                        }
                    else
                        null;
                },
            }
        }

        pub fn beginBookmark(self: *Self, allocator: Allocator) Allocator.Error!void {
            if (allow_lambdas) {
                var bookmark = try allocator.create(Bookmark);
                bookmark.* = .{
                    .prev = self.bookmark.stack,
                    .index = self.index,
                };

                self.bookmark.stack = bookmark;
                if (options.source == .Stream) {
                    if (self.stream.preserve_bookmark) |preserve| {
                        assert(preserve <= self.index);
                    } else {
                        self.stream.preserve_bookmark = self.index;
                    }
                }
            }
        }

        pub fn endBookmark(self: *Self, allocator: Allocator) Allocator.Error!?RefCountedSlice {
            if (allow_lambdas) {
                if (self.bookmark.stack) |bookmark| {
                    defer {
                        self.bookmark.stack = bookmark.prev;
                        if (options.source == .Stream and bookmark.prev == null) {
                            self.stream.preserve_bookmark = null;
                        }
                        allocator.destroy(bookmark);
                    }

                    assert(bookmark.index < self.content.len);
                    assert(bookmark.index <= self.bookmark.last_starting_mark);
                    assert(self.bookmark.last_starting_mark < self.content.len);

                    return RefCountedSlice{
                        .content = self.content[bookmark.index..self.bookmark.last_starting_mark],
                        .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                    };
                }
            }

            return null;
        }

        fn adjustBookmarkOffset(bookmark: ?*Bookmark, off_set: u32) void {
            if (allow_lambdas) {
                if (bookmark) |current| {
                    assert(current.index >= off_set);
                    current.index -= off_set;
                    adjustBookmarkOffset(current.prev, off_set);
                }
            }
        }

        fn freeBookmarks(allocator: Allocator, bookmark: ?*Bookmark) void {
            if (allow_lambdas) {
                if (bookmark) |current| {
                    freeBookmarks(allocator, current.prev);
                    allocator.destroy(current);
                }
            }
        }
    };
}

const TestTextScanner = TextScanner(.{
    .source = .{ .String = .{} },
    .output = .Render,
});

test "basic tests" {
    const content =
        \\Hello{{tag1}}
        \\World{{{ tag2 }}}Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try expectTag(.static_text, "Hello", part_1, 1, 6);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_2, 1, 12);
    defer part_2.?.unRef(allocator);

    var part_3 = try reader.next(allocator);
    try expectTag(.static_text, "\nWorld", part_3, 2, 6);
    defer part_3.?.unRef(allocator);

    var part_4 = try reader.next(allocator);
    try expectTag(.triple_mustache, " tag2 ", part_4, 2, 15);
    defer part_4.?.unRef(allocator);

    var part_5 = try reader.next(allocator);
    try expectTag(.static_text, "Until eof", part_5, 2, 27);
    defer part_5.?.unRef(allocator);

    var part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "custom tags" {
    const content =
        \\Hello[tag1]
        \\World[ tag2 ]Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try expectTag(.static_text, "Hello", part_1, 1, 6);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_2, 1, 11);
    defer part_2.?.unRef(allocator);

    var part_3 = try reader.next(allocator);
    try expectTag(.static_text, "\nWorld", part_3, 2, 6);
    defer part_3.?.unRef(allocator);

    var part_4 = try reader.next(allocator);
    try expectTag(.interpolation, " tag2 ", part_4, 2, 13);
    defer part_4.?.unRef(allocator);

    var part_5 = try reader.next(allocator);
    try expectTag(.static_text, "Until eof", part_5, 2, 23);
    defer part_5.?.unRef(allocator);

    var part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "EOF" {
    const content = "{{tag1}}";

    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_1, 1, 4);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try expectTag(.interpolation, "tag1", part_1, 1, 6);
    defer part_1.?.unRef(allocator);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 == null);
}

test "bookmarks" {

    //               0          1        2         3         4         5         6         7         8
    //               01234567890123456789012345678901234567890123456789012345678901234567890123456789012345
    //                ↓          ↓               ↓          ↓         ↓          ↓             ↓          ↓
    const content = "{{#section1}}begin_content1{{#section2}}content2{{/section2}}end_content1{{/section1}}";
    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try expectTag(.section, "section1", part_1, 1, 12);
    defer part_1.?.unRef(allocator);

    try reader.beginBookmark(allocator);

    var part_2 = try reader.next(allocator);
    try expectTag(.static_text, "begin_content1", part_2, 1, 28);
    defer part_2.?.unRef(allocator);

    var part_3 = try reader.next(allocator);
    try expectTag(.section, "section2", part_3, 1, 39);
    defer part_3.?.unRef(allocator);

    try reader.beginBookmark(allocator);

    var part_4 = try reader.next(allocator);
    try expectTag(.static_text, "content2", part_4, 1, 49);
    defer part_4.?.unRef(allocator);

    var part_5 = try reader.next(allocator);
    try expectTag(.close_section, "section2", part_5, 1, 60);
    defer part_5.?.unRef(allocator);

    if (try reader.endBookmark(allocator)) |*bookmark_1| {
        try testing.expectEqualStrings("content2", bookmark_1.content);
        bookmark_1.ref_counter.free(allocator);
    } else {
        try testing.expect(false);
    }

    var part_6 = try reader.next(allocator);
    try expectTag(.static_text, "end_content1", part_6, 1, 74);
    defer part_6.?.unRef(allocator);

    var part_7 = try reader.next(allocator);
    try expectTag(.close_section, "section1", part_7, 1, 85);
    defer part_7.?.unRef(allocator);

    if (try reader.endBookmark(allocator)) |*bookmark_2| {
        try testing.expectEqualStrings("begin_content1{{#section2}}content2{{/section2}}end_content1", bookmark_2.content);
        bookmark_2.ref_counter.free(allocator);
    } else {
        try testing.expect(false);
    }

    var part_8 = try reader.next(allocator);
    try testing.expect(part_8 == null);
}

fn expectTag(part_type: PartType, content: []const u8, value: anytype, lin: u32, col: u32) !void {
    if (value) |part| {
        try testing.expectEqual(part_type, part.part_type);
        try testing.expectEqualStrings(content, part.content);
        _ = lin;
        _ = col;
        //try testing.expectEqual(lin, part.lin);
        //try testing.expectEqual(col, part.col);
    } else {
        try testing.expect(false);
    }
}
