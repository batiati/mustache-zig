///
/// Seeks a string for a events such as '{{', '}}' or a EOF
/// It is the first stage of the parsing process, the TextScanner produces TextBlocks to be parsed as mustache elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Options = mustache.Options;
const ParseError = mustache.ParseError;

const memory = @import("../memory.zig");

const parsing = @import("parsing.zig");
const Event = parsing.Event;
const Mark = parsing.Mark;
const MarkType = parsing.MarkType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const FileReader = parsing.FileReader;
const Trimmer = parsing.Trimmer;

pub fn TextScanner(comptime options: Options) type {
    const RefCounter = memory.RefCounter(options);
    const RefCountedSlice = memory.RefCountedSlice(options);
    const TextBlock = parsing.TextBlock(options);

    return struct {
        const Self = @This();

        const State = union(enum) {
            Finished,
            ExpectingMark: MarkType,
        };

        const Bookmark = struct {
            prev: ?*@This(),
            index: usize,
        };

        stream: switch (options.source) {
            .Stream => struct {
                reader: *FileReader(options),
                ref_counter: RefCounter = .{},
                preserve: ?usize = null,
            },
            .String => void,
        } = undefined,

        bookmark: struct {
            stack: ?*Bookmark = null,
            starting_mark: usize = 0,
        } = .{},

        content: []const u8 = &.{},
        index: usize = 0,
        block_index: usize = 0,

        state: State = .{ .ExpectingMark = .Starting },
        lin: u32 = 1,
        col: u32 = 1,

        delimiters: Delimiters = undefined,
        delimiter_max_size: u32 = 0,

        ///
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
                    const adjust: struct { off_set: usize, preserve: ?usize } = adjust: {

                        // block_index: initial index of the current TextBlock, the minimum part needed
                        // bookmark.starting_mark: index of the last starting mark '{{', used to determine the inner_text between two tags
                        const last_index = if (self.bookmark.stack == null) self.block_index else std.math.min(self.block_index, self.bookmark.starting_mark);

                        if (self.stream.preserve) |preserve| {

                            // Only when reading from Stream
                            // stream.preserve: is the index of the first pending bookmark

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

                    if (self.bookmark.stack != null) {
                        adjustBookmarkOffset(self.bookmark.stack, adjust.off_set);
                        self.bookmark.starting_mark -= adjust.off_set;
                    }

                    self.stream.preserve = adjust.preserve;
                }
            }
        }

        ///
        /// Reads until the next delimiter mark or EOF
        pub fn next(self: *Self, allocator: Allocator) !?TextBlock {
            switch (self.state) {
                .Finished => return null,
                .ExpectingMark => |expected_mark| {
                    self.block_index = self.index;
                    var trimmer = Trimmer(Self){ .text_scanner = self };

                    while (self.index < self.content.len or
                        (options.source == .Stream and !self.stream.reader.finished()))
                    {
                        if (options.source == .Stream) {
                            // Request a new slice if near to the end
                            if (self.content.len == 0 or
                                self.index + self.delimiter_max_size + 1 >= self.content.len)
                            {
                                try self.requestContent(allocator);
                            }
                        }

                        // Increment the index on defer
                        var increment: u32 = 1;
                        defer {
                            if (self.content[self.index] == '\n') {
                                self.lin += 1;
                                self.col = 1;
                            } else {
                                self.col += increment;
                            }

                            self.index += increment;
                        }

                        if (self.matchTagMark(expected_mark)) |mark| {
                            self.state = .{ .ExpectingMark = if (expected_mark == .Starting) .Ending else .Starting };
                            increment = mark.delimiter_len;

                            if (mark.mark_type == .Starting) {
                                self.bookmark.starting_mark = self.index;
                            }

                            const tail = if (self.index > self.block_index) self.content[self.block_index..self.index] else null;
                            return TextBlock{
                                .event = .{ .Mark = mark },
                                .tail = tail,
                                .ref_counter = if (options.source == .Stream and tail != null) self.stream.ref_counter.ref() else .{},
                                .lin = self.lin,
                                .col = self.col,
                                .left_trimming = trimmer.getLeftTrimmingIndex(),
                                .right_trimming = trimmer.getRightTrimmingIndex(),
                            };
                        }

                        if (expected_mark == .Starting) {

                            // We just need to keep track of trimming on the text outside tags
                            // The text inside, like "{{blahblah}}"" will never be trimmed
                            trimmer.move();
                        }
                    }

                    // EOF reached, no more parts left
                    self.state = .Finished;

                    const tail = if (self.block_index < self.content.len) self.content[self.block_index..] else null;
                    return TextBlock{
                        .event = .Eof,
                        .tail = tail,
                        .ref_counter = if (options.source == .Stream and tail != null) self.stream.ref_counter.ref() else .{},
                        .lin = self.lin,
                        .col = self.col,
                        .left_trimming = trimmer.getLeftTrimmingIndex(),
                        .right_trimming = trimmer.getRightTrimmingIndex(),
                    };
                },
            }
        }

        pub fn beginBookmark(self: *Self, allocator: Allocator) Allocator.Error!void {
            var bookmark = try allocator.create(Bookmark);
            bookmark.* = .{
                .prev = self.bookmark.stack,
                .index = self.index,
            };

            self.bookmark.stack = bookmark;
            if (options.source == .Stream) {
                if (self.stream.preserve) |preserve| {
                    assert(preserve <= self.index);
                } else {
                    self.stream.preserve = self.index;
                }
            }
        }

        pub fn endBookmark(self: *Self, allocator: Allocator) Allocator.Error!?RefCountedSlice {
            if (self.bookmark.stack) |bookmark| {
                defer {
                    self.bookmark.stack = bookmark.prev;
                    if (options.source == .Stream and bookmark.prev == null) {
                        self.stream.preserve = null;
                    }
                    allocator.destroy(bookmark);
                }

                assert(bookmark.index < self.content.len);
                assert(bookmark.index <= self.bookmark.starting_mark);
                assert(self.bookmark.starting_mark < self.content.len);

                return RefCountedSlice{
                    .content = self.content[bookmark.index..self.bookmark.starting_mark],
                    .ref_counter = if (options.source == .Stream) self.stream.ref_counter.ref() else .{},
                };
            } else {
                return null;
            }
        }

        fn adjustBookmarkOffset(bookmark: ?*Bookmark, off_set: usize) void {
            if (bookmark) |current| {
                assert(current.index >= off_set);
                current.index -= off_set;
                adjustBookmarkOffset(current.prev, off_set);
            }
        }

        fn freeBookmarks(allocator: Allocator, bookmark: ?*Bookmark) void {
            if (bookmark) |current| {
                freeBookmarks(allocator, current.prev);
                allocator.destroy(current);
            }
        }

        fn matchTagMark(self: *Self, expected_mark: MarkType) ?Mark {
            const slice = self.content[self.index..];
            return switch (expected_mark) {
                .Starting => matchTagMarkType(.Starting, slice, self.delimiters.starting_delimiter),
                .Ending => matchTagMarkType(.Ending, slice, self.delimiters.ending_delimiter),
            };
        }

        inline fn matchTagMarkType(comptime mark_type: MarkType, slice: []const u8, delimiter: []const u8) ?Mark {
            const match = std.mem.startsWith(u8, slice, delimiter);
            if (match) {
                const is_triple_mustache = slice.len > delimiter.len and slice[delimiter.len] == if (mark_type == .Starting) '{' else '}';

                return Mark{
                    .mark_type = mark_type,
                    .delimiter_type = if (is_triple_mustache) .NoScapeDelimiter else .Regular,
                    .delimiter_len = @intCast(u32, if (is_triple_mustache) delimiter.len + 1 else delimiter.len),
                };
            } else {
                return null;
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
    try testing.expect(part_1 != null);
    defer part_1.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_1.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 12), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 3), part_3.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.lin);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 3), part_4.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.lin);
    try testing.expectEqual(@as(usize, 15), part_4.?.col);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.unRef(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.lin);
    try testing.expectEqual(@as(usize, 27), part_5.?.col);

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
    defer part_1.?.unRef(allocator);

    try expectMark(.Starting, part_1, "Hello", 1, 6);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);

    var part_2 = try reader.next(allocator);
    defer part_2.?.unRef(allocator);

    try expectMark(.Ending, part_2, "tag1", 1, 11);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_2.?.event.Mark.delimiter_len);

    var part_3 = try reader.next(allocator);
    defer part_3.?.unRef(allocator);

    try expectMark(.Starting, part_3, "\nWorld", 2, 6);
    try testing.expectEqual(DelimiterType.Regular, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_3.?.event.Mark.delimiter_len);

    var part_4 = try reader.next(allocator);
    defer part_4.?.unRef(allocator);

    try expectMark(.Ending, part_4, " tag2 ", 2, 13);
    try testing.expectEqual(DelimiterType.Regular, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_4.?.event.Mark.delimiter_len);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.unRef(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.lin);
    try testing.expectEqual(@as(usize, 23), part_5.?.col);

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
    defer part_1.?.unRef(allocator);

    try expectMark(.Starting, part_1, null, 1, 1);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_1.?.event.Mark.delimiter_len);

    var part_2 = try reader.next(allocator);
    defer part_2.?.unRef(allocator);

    try expectMark(.Ending, part_2, "tag1", 1, 7);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_2.?.event.Mark.delimiter_len);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.unRef(allocator);
    try testing.expectEqual(Event.Eof, part_3.?.event);
    try testing.expect(part_3.?.tail == null);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    const allocator = testing.allocator;

    var reader = try TestTextScanner.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    defer part_1.?.unRef(allocator);

    try expectMark(.Starting, part_1, null, 1, 1);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);

    var part_2 = try reader.next(allocator);
    defer part_2.?.unRef(allocator);

    try expectMark(.Ending, part_2, "tag1", 1, 6);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);

    var part_3 = try reader.next(allocator);
    defer part_3.?.unRef(allocator);
    try testing.expect(part_3 != null);
    try testing.expectEqual(Event.Eof, part_3.?.event);
    try testing.expect(part_3.?.tail == null);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 == null);
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
    defer part_1.?.unRef(allocator);
    try expectMark(.Starting, part_1, null, 1, 1);

    var part_2 = try reader.next(allocator);
    defer part_2.?.unRef(allocator);
    try expectMark(.Ending, part_2, "#section1", 1, 12);

    try reader.beginBookmark(allocator);

    var part_3 = try reader.next(allocator);
    defer part_3.?.unRef(allocator);
    try expectMark(.Starting, part_3, "begin_content1", 1, 28);

    var part_4 = try reader.next(allocator);
    defer part_4.?.unRef(allocator);

    try expectMark(.Ending, part_4, "#section2", 1, 39);

    try reader.beginBookmark(allocator);

    var part_5 = try reader.next(allocator);
    defer part_5.?.unRef(allocator);
    try expectMark(.Starting, part_5, "content2", 1, 49);

    var part_6 = try reader.next(allocator);
    defer part_6.?.unRef(allocator);
    try expectMark(.Ending, part_6, "/section2", 1, 60);

    if (try reader.endBookmark(allocator)) |*bookmark_1| {
        try testing.expectEqualStrings("content2", bookmark_1.content);
        bookmark_1.ref_counter.free(allocator);
    } else {
        try testing.expect(false);
    }

    var part_7 = try reader.next(allocator);
    defer part_7.?.unRef(allocator);
    try expectMark(.Starting, part_7, "end_content1", 1, 74);

    var part_8 = try reader.next(allocator);
    defer part_8.?.unRef(allocator);
    try expectMark(.Ending, part_8, "/section1", 1, 85);

    if (try reader.endBookmark(allocator)) |*bookmark_2| {
        try testing.expectEqualStrings("begin_content1{{#section2}}content2{{/section2}}end_content1", bookmark_2.content);
        bookmark_2.ref_counter.free(allocator);
    } else {
        try testing.expect(false);
    }

    var part_9 = try reader.next(allocator);
    try testing.expect(part_9 != null);
    try testing.expect(part_9.?.event == .Eof);

    var part_10 = try reader.next(allocator);
    try testing.expect(part_10 == null);
}

fn expectMark(mark_type: MarkType, value: anytype, content: ?[]const u8, lin: u32, col: u32) !void {
    if (value) |part| {
        try testing.expectEqual(Event.Mark, part.event);
        try testing.expectEqual(mark_type, part.event.Mark.mark_type);

        if (content) |content_value| {
            try testing.expect(part.tail != null);
            try testing.expectEqualStrings(content_value, part.tail.?);
        } else {
            try testing.expect(part.tail == null);
        }

        try testing.expectEqual(lin, part.lin);
        try testing.expectEqual(col, part.col);
    } else {
        try testing.expect(false);
    }
}
