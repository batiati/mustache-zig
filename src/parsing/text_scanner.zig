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

const mem = @import("../mem.zig");
const RefCounter = mem.RefCounter;
const RefCounterHolder = mem.RefCounterHolder;

pub const TextSource = enum { String, File };

pub fn TextScanner(comptime source: TextSource) type {
    return struct {
        const Self = @This();
        const State = union(enum) {
            Finished,
            ExpectingMark: MarkType,
        };

        reader: if (source == .File) *FileReader else void,
        ref_counter: if (source == .File) RefCounter else void = if (source == .File) .{} else {},

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
            switch (self.state) {
                .Finished => return null,
                .ExpectingMark => |expected_mark| {
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

                        if (self.matchTagMark(expected_mark)) |mark| {
                            self.state = .{ .ExpectingMark = if (expected_mark == .Starting) .Ending else .Starting };
                            increment = mark.delimiter_len;

                            const tail = if (self.index > self.block_index) self.content[self.block_index..self.index] else null;
                            return TextBlock{
                                .event = .{ .Mark = mark },
                                .tail = tail,
                                .ref_counter = if (source == .File and tail != null) self.ref_counter.ref() else .{},
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
                        .ref_counter = if (source == .File and tail != null) self.ref_counter.ref() else .{},
                        .lin = self.lin,
                        .col = self.col,
                        .left_trimming = trimmer.getLeftTrimmingIndex(),
                        .right_trimming = trimmer.getRightTrimmingIndex(),
                    };
                },
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

// Aggregates multiple slices into a single buffer
pub fn Bookmarking(comptime is_ref_counted: bool) type {
    return struct {
        const Self = @This();

        ref_counters: if (is_ref_counted) RefCounterHolder else void = if (is_ref_counted) .{} else {},
        segments: std.ArrayListUnmanaged(Segment) = .{},

        const Segment = union(enum) {
            First: struct {
                slice: []const u8,
                start: usize,
            },

            Next: []const u8,

            pub inline fn ptr(self: Segment) [*]const u8 {
                return switch (self) {
                    .First => |value| value.slice.ptr,
                    .Next => |value| value.ptr,
                };
            }
        };

        pub const Result = struct {
            slice: []const u8,
            ref_counter: RefCounter,
        };

        pub fn append(self: *Self, allocator: Allocator, ref_counter: RefCounter, slice: []const u8, start: usize) Allocator.Error!void {

            // Same slice, no need to add a new segment
            if (self.peek()) |last| if (last.ptr() == slice.ptr) return;

            const segment: Segment = if (self.segments.items.len == 0) .{ .First = .{ .slice = slice, .start = start } } else .{ .Next = slice };
            if (is_ref_counted) try self.ref_counters.add(allocator, ref_counter);
            try self.segments.append(allocator, segment);
        }

        pub fn getResult(self: *Self, allocator: Allocator, end: usize) Allocator.Error!Result {
            if (self.segments.items.len == 0) {
                return Result{
                    .slice = &.{},
                    .ref_counter = RefCounter.nullRef,
                };
            } else if (self.segments.items.len == 1) {
                assert(self.segments.items[0] == .First);

                const first = self.segments.items[0].First;
                assert(end >= first.start);
                assert(end < first.slice.len);

                const ref_counter = blk: {
                    if (is_ref_counted) {
                        var iterator = self.ref_counters.iterator();
                        if (iterator.next()) |source_ref_counter| {
                            break :blk source_ref_counter.ref();
                        }
                    }

                    break :blk RefCounter.nullRef;
                };

                return Result{
                    .slice = first.slice[first.start..end],
                    .ref_counter = ref_counter,
                };
            } else {
                var list = std.ArrayListUnmanaged(u8){};
                errdefer list.deinit(allocator);

                for (self.segments.items) |segment, i| {
                    const is_last = i + 1 == self.segments.items.len;
                    const slice = switch (segment) {
                        .First => |value| if (is_last) value.slice[value.start..end] else value.slice[value.start..],
                        .Next => |value| if (is_last) value[0..end] else value,
                    };

                    try list.appendSlice(allocator, slice);
                }

                const buffer = list.toOwnedSlice(allocator);
                errdefer allocator.free(buffer);

                return Result{
                    .slice = buffer,
                    .ref_counter = try RefCounter.init(allocator, buffer),
                };
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.segments.deinit(allocator);
            if (is_ref_counted) self.ref_counters.free(allocator);
        }

        fn peek(self: *Self) ?Segment {
            if (self.segments.items.len == 0) {
                return null;
            } else {
                return self.segments.items[self.segments.items.len - 1];
            }
        }
    };
}

test "Bookmarking" {
    const tester = struct {
        pub fn doTheTest(comptime is_ref_counted: bool) !void {
            const allocator = testing.allocator;

            const slice_1 = try allocator.dupe(u8, "ABCDEFGHIJKLMNOPQRSTUVXYZ");
            var ref_counter_1 = if (is_ref_counted) try RefCounter.init(allocator, slice_1) else RefCounter.nullRef;
            defer if (is_ref_counted) ref_counter_1.free(allocator) else allocator.free(slice_1);

            const slice_2 = try allocator.dupe(u8, "0123456789012345678901234567890");
            var ref_counter_2 = if (is_ref_counted) try RefCounter.init(allocator, slice_2) else RefCounter.nullRef;
            defer if (is_ref_counted) ref_counter_2.free(allocator) else allocator.free(slice_2);

            const Impl = Bookmarking(is_ref_counted);

            {
                // Empty
                var aggregator = Impl{};
                defer aggregator.deinit(allocator);

                var result = try aggregator.getResult(allocator, 0);
                defer result.ref_counter.free(allocator);

                try testing.expectEqualStrings("", result.slice);
            }

            {
                // Single call
                var aggregator = Impl{};
                defer aggregator.deinit(allocator);

                try aggregator.append(allocator, ref_counter_1, slice_1, 5);

                var result = try aggregator.getResult(allocator, 8);
                defer result.ref_counter.free(allocator);

                try testing.expectEqualStrings("FGH", result.slice);
            }

            {
                // Multiple call
                var aggregator = Impl{};
                defer aggregator.deinit(allocator);

                try aggregator.append(allocator, ref_counter_1, slice_1, 5);
                try aggregator.append(allocator, ref_counter_1, slice_1, 8);
                try aggregator.append(allocator, ref_counter_1, slice_1, 10);

                var result = try aggregator.getResult(allocator, 12);
                defer result.ref_counter.free(allocator);

                try testing.expectEqualStrings("FGHIJKL", result.slice);
            }

            {
                // Multiple slices
                var aggregator = Impl{};
                defer aggregator.deinit(allocator);

                try aggregator.append(allocator, ref_counter_1, slice_1, 18);
                try aggregator.append(allocator, ref_counter_2, slice_2, 0);

                var result = try aggregator.getResult(allocator, 5);
                defer result.ref_counter.free(allocator);

                try testing.expectEqualStrings("STUVXYZ01234", result.slice);
            }
        }
    };

    try tester.doTheTest(true);
    try tester.doTheTest(false);
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

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 11), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_3.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.lin);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_4.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.lin);
    try testing.expectEqual(@as(usize, 13), part_4.?.col);

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

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_1.?.event.Mark.delimiter_len);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 2), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 7), part_2.?.col);

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

    var reader = try TextScanner(.String).init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_1.?.event.Mark.delimiter_len);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.lin);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.unRef(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqual(@as(u32, 1), part_2.?.event.Mark.delimiter_len);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.lin);
    try testing.expectEqual(@as(usize, 6), part_2.?.col);

    var part_3 = try reader.next(allocator);
    defer part_3.?.unRef(allocator);
    try testing.expect(part_3 != null);
    try testing.expectEqual(Event.Eof, part_3.?.event);
    try testing.expect(part_3.?.tail == null);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 == null);
}
