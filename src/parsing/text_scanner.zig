///
/// Seeks a string for a events such as '{{', '}}' or a EOF
/// It is the first stage of the parsing process, the TextScanner produces TextBlocks to be parsed as mustache elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const ParseError = mustache.ParseError;

const parsing = @import("parsing.zig");
const Event = parsing.Event;
const Mark = parsing.Mark;
const MarkType = parsing.MarkType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const TextBlock = parsing.TextBlock;
const Trimmer = parsing.Trimmer;
const FileReader = parsing.FileReader;

const RefCounter = @import("../mem.zig").RefCounter;

pub const TextSource = enum { String, File };

pub fn TextScanner(comptime source: TextSource) type {
    return struct {
        const Self = @This();

        reader: if (source == .File) *FileReader else void,
        ref_counter: if (source == .File) RefCounter else void = if (source == .File) .{} else {},

        content: []const u8 = &.{},
        index: usize = 0,
        block_index: usize = 0,
        expected_mark: MarkType = .Starting,
        lin: u32 = 1,
        col: u32 = 1,
        delimiters: Delimiters = undefined,
        delimiter_max_size: u32 = 0,

        ///
        /// Should be the template content if source == .String
        /// or the absolute path if source == .File
        pub fn init(allocator: Allocator, template: []const u8) if (source == .String) Allocator.Error!Self else FileReader.Error!Self {
            switch (source) {
                .String => return Self{
                    .content = template,
                    .reader = {},
                },
                .File => return Self{
                    .reader = try FileReader.initFromPath(allocator, template, 4 * 1024),
                },
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (source == .File) {
                self.ref_counter.free(allocator);
                self.reader.deinit(allocator);
            }
        }

        pub fn setDelimiters(self: *Self, delimiters: Delimiters) ParseError!void {
            if (delimiters.starting_delimiter.len == 0) return ParseError.InvalidDelimiters;
            if (delimiters.ending_delimiter.len == 0) return ParseError.InvalidDelimiters;

            self.delimiter_max_size = @intCast(u32, std.math.max(delimiters.starting_delimiter.len, delimiters.ending_delimiter.len) + 1);
            self.delimiters = delimiters;
        }

        fn requestContent(self: *Self, allocator: Allocator) !void {
            if (source == .File) {
                if (!self.reader.finished()) {
                    const prepend = self.content[self.block_index..];

                    const read = try self.reader.read(allocator, prepend);
                    errdefer read.ref_counter.free(allocator);

                    self.ref_counter.free(allocator);
                    self.ref_counter = read.ref_counter;

                    self.content = read.content;
                    self.index -= self.block_index;
                    self.block_index = 0;
                }
            }
        }

        ///
        /// Reads until the next delimiter mark or EOF
        pub fn next(self: *Self, allocator: Allocator) !?TextBlock {
            self.block_index = self.index;
            var trimmer = Trimmer(source){ .text_scanner = self };

            while (self.index < self.content.len or
                (source == .File and !self.reader.finished()))
            {
                if (source == .File) {
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

                if (self.matchTagMark()) |mark| {
                    const tail = if (self.index > self.block_index) self.content[self.block_index..self.index] else null;

                    const block = TextBlock{
                        .event = .{ .Mark = mark },
                        .tail = tail,
                        .ref_counter = if (source == .File and tail != null) self.ref_counter.ref() else .{},
                        .lin = self.lin,
                        .col = self.col,
                        .left_trimming = trimmer.getLeftTrimmingIndex(),
                        .right_trimming = trimmer.getRightTrimmingIndex(),
                    };

                    increment = mark.delimiter_len;

                    return block;
                }

                trimmer.move();

                if (self.index == self.content.len - 1) {
                    return TextBlock{
                        .event = .Eof,
                        .tail = self.content[self.block_index..],
                        .ref_counter = if (source == .File) self.ref_counter.ref() else .{},
                        .lin = self.lin,
                        .col = self.col,
                        .left_trimming = trimmer.getLeftTrimmingIndex(),
                        .right_trimming = trimmer.getRightTrimmingIndex(),
                    };
                }
            }

            // No more parts
            return null;
        }

        fn matchTagMark(self: *Self) ?Mark {
            const slice = self.content[self.index..];

            switch (self.expected_mark) {
                .Starting => {
                    const match = std.mem.startsWith(u8, slice, self.delimiters.starting_delimiter);
                    if (match) {
                        self.expected_mark = .Ending;
                        const is_triple_mustache = slice.len > self.delimiters.starting_delimiter.len and slice[self.delimiters.starting_delimiter.len] == '{';

                        return Mark{
                            .mark_type = .Starting,
                            .delimiter_type = if (is_triple_mustache) .NoScapeDelimiter else .Regular,
                            .delimiter_len = @intCast(u32, if (is_triple_mustache) self.delimiters.starting_delimiter.len + 1 else self.delimiters.starting_delimiter.len),
                        };
                    }
                },
                .Ending => {
                    const match = std.mem.startsWith(u8, slice, self.delimiters.ending_delimiter);
                    if (match) {
                        self.expected_mark = .Starting;
                        const is_triple_mustache = slice.len > self.delimiters.ending_delimiter.len and slice[self.delimiters.ending_delimiter.len] == '}';

                        return Mark{
                            .mark_type = .Ending,
                            .delimiter_type = if (is_triple_mustache) .NoScapeDelimiter else .Regular,
                            .delimiter_len = @intCast(u32, if (is_triple_mustache) self.delimiters.ending_delimiter.len + 1 else self.delimiters.ending_delimiter.len),
                        };
                    }
                },
            }

            return null;
        }
    };
}

const testing = std.testing;
test "basic tests" {
    const content =
        \\Hello{{tag1}}
        \\World{{{ tag2 }}}Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_1.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 12), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 3), part_3.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.lin);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 3), part_4.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.lin);
    try testing.expectEqual(@as(usize, 15), part_4.?.col);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.deinit(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.lin);
    try testing.expectEqual(@as(usize, 26), part_5.?.col);

    var part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "custom tags" {
    const content =
        \\Hello[tag1]
        \\World[ tag2 ]Until eof
    ;

    const allocator = testing.allocator;

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 11), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_3.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.lin);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_4.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.lin);
    try testing.expectEqual(@as(usize, 13), part_4.?.col);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.deinit(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.lin);
    try testing.expectEqual(@as(usize, 22), part_5.?.col);

    var part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "EOF" {
    const content = "{{tag1}}";

    const allocator = testing.allocator;

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_1.?.event.Mark.delimiter_len);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 7), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    const allocator = testing.allocator;

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 6), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 == null);
}
