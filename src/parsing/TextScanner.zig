///
/// Seeks a string for a events such as '{{', '}}' or a EOF
/// It is the first stage of the parsing process, the TextScanner produces TextBlocks to be parsed as mustache elements.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const ParseErrors = mustache.template.ParseErrors;

const parsing = @import("parsing.zig");
const Event = parsing.Event;
const Mark = parsing.Mark;
const MarkType = parsing.MarkType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const TextBlock = parsing.TextBlock;
const Trimmer = parsing.Trimmer;

const text = @import("text.zig");
const TextReader = text.TextReader;

const RefCounter = @import("../mem.zig").RefCounter;

const Self = @This();

///
/// Mustache allows changing delimiters while processing the text, by special tags {{=[ ]=}}
/// Implements a list of runtime-known delimiters to split the text
///
/// Triple-mustache delimiters '{{{' and ''}}}' are fixed
/// It is not defined by mustache's specs, but some implementations use the current delimiter + '{' or '}' to represent the unescaped tag.
/// The '&' symbol can be used instead of the triple-mustache for custom delimiters use cases.
const MAX_DELIMITERS = 4;

const Delimiter = struct {
    delimiter: []const u8,
    mark_type: MarkType,
    delimiter_type: DelimiterType,

    pub inline fn match(self: Delimiter, slice: []const u8) ?Mark {
        if (std.mem.startsWith(u8, slice, self.delimiter)) {
            return Mark{
                .mark_type = self.mark_type,
                .delimiter_type = self.delimiter_type,
                .delimiter = self.delimiter,
            };
        } else {
            return null;
        }
    }
};

reader: TextReader,
ref_counter: RefCounter = .{},
content: []const u8 = &.{},
index: usize = 0,
block_index: usize = 0,
row: u32 = 1,
col: u32 = 1,
delimiters: [MAX_DELIMITERS]Delimiter = undefined,
delimiters_count: u4 = 0,
delimiter_max_size: u32 = 0,

pub fn init(allocator: Allocator, template_text: []const u8) Allocator.Error!Self {
    return Self{
        .reader = try text.fromString(allocator, template_text),
    };
}

pub fn initFromFile(allocator: Allocator, absolute_path: []const u8, read_buffer_size: usize) text.Errors!Self {
    return Self{
        .reader = try text.fromFile(allocator, absolute_path, read_buffer_size),
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.ref_counter.free(allocator);
    self.reader.deinit(allocator);
}

pub fn setDelimiters(self: *Self, delimiters: Delimiters) ParseErrors!void {
    if (delimiters.starting_delimiter.len == 0) return ParseErrors.InvalidDelimiters;
    if (delimiters.ending_delimiter.len == 0) return ParseErrors.InvalidDelimiters;

    var index: u4 = 0;
    var delimiter_max_size = std.math.max(Delimiters.NoScapeStartingDelimiter.len, Delimiters.NoScapeEndingDelimiter.len);

    if (!std.mem.eql(u8, delimiters.starting_delimiter, Delimiters.NoScapeStartingDelimiter)) {
        self.delimiters[index] = .{
            .delimiter = Delimiters.NoScapeStartingDelimiter,
            .mark_type = .Starting,
            .delimiter_type = .NoScapeDelimiter,
        };
        index += 1;
    }

    if (!std.mem.eql(u8, delimiters.ending_delimiter, Delimiters.NoScapeEndingDelimiter)) {
        self.delimiters[index] = .{
            .delimiter = Delimiters.NoScapeEndingDelimiter,
            .mark_type = .Ending,
            .delimiter_type = .NoScapeDelimiter,
        };
        index += 1;
    }

    if (std.mem.eql(u8, delimiters.starting_delimiter, delimiters.ending_delimiter)) {
        self.delimiters[index] = .{
            .delimiter = delimiters.starting_delimiter,
            .mark_type = .Both,
            .delimiter_type = .Regular,
        };
        index += 1;
        if (delimiters.starting_delimiter.len > delimiter_max_size) delimiter_max_size = delimiters.starting_delimiter.len;
    } else {
        self.delimiters[index] = .{
            .delimiter = delimiters.starting_delimiter,
            .mark_type = .Starting,
            .delimiter_type = .Regular,
        };
        index += 1;
        if (delimiters.starting_delimiter.len > delimiter_max_size) delimiter_max_size = delimiters.starting_delimiter.len;

        self.delimiters[index] = .{
            .delimiter = delimiters.ending_delimiter,
            .mark_type = .Ending,
            .delimiter_type = .Regular,
        };
        index += 1;
        if (delimiters.ending_delimiter.len > delimiter_max_size) delimiter_max_size = delimiters.ending_delimiter.len;
    }

    // Order desc by the delimiter length, avoiding ambiguity during the "startsWith" comparison
    const order = struct {
        pub fn desc(context: void, lhs: Delimiter, rhs: Delimiter) bool {
            _ = context;

            return lhs.delimiter.len >= rhs.delimiter.len;
        }
    };

    self.delimiters_count = index;
    std.sort.sort(Delimiter, self.delimiters[0..self.delimiters_count], {}, order.desc);
}

fn requestContent(self: *Self, allocator: Allocator) !void {
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

///
/// Reads until the next delimiter mark or EOF
pub fn next(self: *Self, allocator: Allocator) !?TextBlock {
    self.block_index = self.index;
    var trimmer = Trimmer{ .text_scanner = self };

    while (self.index < self.content.len or
        !self.reader.finished())
    {
        // Request a new slice if near to the end
        if (self.content.len == 0 or
            self.index + self.delimiter_max_size + 1 >= self.content.len)
        {
            try self.requestContent(allocator);
        }

        // Increment the index on defer
        var increment: u32 = 1;
        defer {
            if (self.content[self.index] == '\n') {
                self.row += 1;
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
                .ref_counter = if (tail != null) self.ref_counter.ref() else .{},
                .row = self.row,
                .col = self.col,
                .left_trimming = trimmer.getLeftTrimmingIndex(),
                .right_trimming = trimmer.getRightTrimmingIndex(),
            };

            increment = @intCast(u32, mark.delimiter.len);

            return block;
        }

        trimmer.move();

        if (self.index == self.content.len - 1) {
            return TextBlock{
                .event = .Eof,
                .tail = self.content[self.block_index..],
                .ref_counter = self.ref_counter.ref(),
                .row = self.row,
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

    if (self.delimiters_count >= 1) {
        if (self.delimiters[0].match(slice)) |mark| return mark;
    }

    if (self.delimiters_count >= 2) {
        if (self.delimiters[1].match(slice)) |mark| return mark;
    }

    if (self.delimiters_count >= 3) {
        if (self.delimiters[2].match(slice)) |mark| return mark;
    }

    if (self.delimiters_count == 4) {
        if (self.delimiters[3].match(slice)) |mark| return mark;
    }

    return null;
}

const testing = std.testing;
test "basic tests" {
    const content =
        \\Hello{{tag1}}
        \\World{{{ tag2 }}}Until eof
    ;

    const allocator = testing.allocator;

    var reader = try Self.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("{{", part_1.?.event.Mark.delimiter);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("}}", part_2.?.event.Mark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 12), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("{{{", part_3.?.event.Mark.delimiter);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.row);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("}}}", part_4.?.event.Mark.delimiter);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.row);
    try testing.expectEqual(@as(usize, 15), part_4.?.col);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.deinit(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.row);
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

    var reader = try Self.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("[", part_1.?.event.Mark.delimiter);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("]", part_2.?.event.Mark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 11), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 != null);
    defer part_3.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_3.?.event);
    try testing.expectEqual(MarkType.Starting, part_3.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_3.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("[", part_3.?.event.Mark.delimiter);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.row);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = try reader.next(allocator);
    try testing.expect(part_4 != null);
    defer part_4.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_4.?.event);
    try testing.expectEqual(MarkType.Ending, part_4.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_4.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("]", part_4.?.event.Mark.delimiter);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.row);
    try testing.expectEqual(@as(usize, 13), part_4.?.col);

    var part_5 = try reader.next(allocator);
    try testing.expect(part_5 != null);
    defer part_5.?.deinit(allocator);

    try testing.expectEqual(Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.row);
    try testing.expectEqual(@as(usize, 22), part_5.?.col);

    var part_6 = try reader.next(allocator);
    try testing.expect(part_6 == null);
}

test "EOF" {
    const content = "{{tag1}}";

    const allocator = testing.allocator;

    var reader = try Self.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{});

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("{{", part_1.?.event.Mark.delimiter);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("}}", part_2.?.event.Mark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 7), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    const allocator = testing.allocator;

    var reader = try Self.init(allocator, content);
    defer reader.deinit(allocator);

    try reader.setDelimiters(.{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = try reader.next(allocator);
    try testing.expect(part_1 != null);
    defer part_1.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_1.?.event);
    try testing.expectEqual(MarkType.Starting, part_1.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("[", part_1.?.event.Mark.delimiter);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = try reader.next(allocator);
    try testing.expect(part_2 != null);
    defer part_2.?.deinit(allocator);

    try testing.expectEqual(Event.Mark, part_2.?.event);
    try testing.expectEqual(MarkType.Ending, part_2.?.event.Mark.mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.Mark.delimiter_type);
    try testing.expectEqualStrings("]", part_2.?.event.Mark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 6), part_2.?.col);

    var part_3 = try reader.next(allocator);
    try testing.expect(part_3 == null);
}
