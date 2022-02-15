const std = @import("std");
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const TemplateOptions = mustache.TemplateOptions;

const TagType = mustache.parser.TagType;
const TagMark = mustache.parser.TagMark;
const TagMarkType = mustache.parser.TagMarkType;
const TextPart = mustache.parser.TextPart;
const DelimiterType = mustache.parser.DelimiterType;
const tokens = mustache.parser.tokens;

const Self = @This();

content: []const u8,
index: usize = 0,
row: usize = 1,
col: usize = 1,
delimiters: Delimiters,

pub fn init(content: []const u8, delimiters: Delimiters) Self {
    return .{
        .content = content,
        .delimiters = delimiters,
    };
}

///
/// Reads until the next event of TAG or EOF
pub fn next(self: *Self) ?TextPart {
    const NEW_LINE = '\n';
    const initial_index = self.index;

    while (self.index < self.content.len) {
        var increment: usize = 1;
        defer {
            if (self.content[self.index] == NEW_LINE) {
                self.row += 1;
                self.col = 1;
            } else {
                self.col += increment;
            }

            self.index += increment;
        }

        if (self.matchTagMark()) |tag_mark| {
            const part = TextPart{
                .event = .{ .TagMark = tag_mark },
                .tail = if (self.index > initial_index) self.content[initial_index..self.index] else null,
                .row = self.row,
                .col = self.col,
            };

            increment = tag_mark.delimiter.len;
            return part;
        } else if (self.index == self.content.len - 1) {
            return TextPart{
                .event = .Eof,
                .tail = self.content[initial_index..],
                .row = self.row,
                .col = self.col,
            };
        }
    }

    return null;
}

fn matchTagMark(self: *Self) ?TagMark {
    const slice = self.content[self.index..];

    if (std.mem.startsWith(u8, slice, Delimiters.NoScapeStartingDelimiter)) {
        return TagMark{
            .tag_mark_type = .Starting,
            .delimiter_type = .NoScapeDelimiter,
            .delimiter = Delimiters.NoScapeStartingDelimiter,
        };
    } else if (std.mem.startsWith(u8, slice, Delimiters.NoScapeEndingDelimiter)) {
        return TagMark{
            .tag_mark_type = .Ending,
            .delimiter_type = .NoScapeDelimiter,
            .delimiter = Delimiters.NoScapeEndingDelimiter,
        };
    } else if (std.mem.startsWith(u8, slice, self.delimiters.starting_delimiter)) {
        return TagMark{
            .tag_mark_type = .Starting,
            .delimiter_type = .Regular,
            .delimiter = self.delimiters.starting_delimiter,
        };
    } else if (std.mem.startsWith(u8, slice, self.delimiters.ending_delimiter)) {
        return TagMark{
            .tag_mark_type = .Ending,
            .delimiter_type = .Regular,
            .delimiter = self.delimiters.ending_delimiter,
        };
    } else {
        return null;
    }
}

const testing = std.testing;
test "basic tests" {
    const content =
        \\Hello{{tag1}}
        \\World{{{ tag2 }}}Until eof
    ;

    var reader = Self.init(content, .{});

    var part_1 = reader.next();
    try testing.expect(part_1 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_1.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_1.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("{{", part_1.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = reader.next();
    try testing.expect(part_2 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_2.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_2.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("}}", part_2.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 12), part_2.?.col);

    var part_3 = reader.next();
    try testing.expect(part_3 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_3.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_3.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_3.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("{{{", part_3.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.row);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = reader.next();
    try testing.expect(part_4 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_4.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_4.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.NoScapeDelimiter, part_4.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("}}}", part_4.?.event.TagMark.delimiter);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.row);
    try testing.expectEqual(@as(usize, 15), part_4.?.col);

    var part_5 = reader.next();
    try testing.expect(part_5 != null);
    try testing.expectEqual(TextPart.Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.row);
    try testing.expectEqual(@as(usize, 26), part_5.?.col);

    var part_6 = reader.next();
    try testing.expect(part_6 == null);
}

test "custom tags" {
    const content =
        \\Hello[tag1]
        \\World[ tag2 ]Until eof
    ;

    var reader = Self.init(content, .{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = reader.next();
    try testing.expect(part_1 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_1.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_1.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("[", part_1.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("Hello", part_1.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 6), part_1.?.col);

    var part_2 = reader.next();
    try testing.expect(part_2 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_2.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_2.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("]", part_2.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 11), part_2.?.col);

    var part_3 = reader.next();
    try testing.expect(part_3 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_3.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_3.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_3.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("[", part_3.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("\nWorld", part_3.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_3.?.row);
    try testing.expectEqual(@as(usize, 6), part_3.?.col);

    var part_4 = reader.next();
    try testing.expect(part_4 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_4.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_4.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_4.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("]", part_4.?.event.TagMark.delimiter);
    try testing.expectEqualStrings(" tag2 ", part_4.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_4.?.row);
    try testing.expectEqual(@as(usize, 13), part_4.?.col);

    var part_5 = reader.next();
    try testing.expect(part_5 != null);
    try testing.expectEqual(TextPart.Event.Eof, part_5.?.event);
    try testing.expectEqualStrings("Until eof", part_5.?.tail.?);
    try testing.expectEqual(@as(usize, 2), part_5.?.row);
    try testing.expectEqual(@as(usize, 22), part_5.?.col);

    var part_6 = reader.next();
    try testing.expect(part_6 == null);
}

test "EOF" {
    const content = "{{tag1}}";

    //var reader = Self.init(content, .{ .starting_delimiter = "[", .ending_delimiter = "]"});
    var reader = Self.init(content, .{});

    var part_1 = reader.next();
    try testing.expect(part_1 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_1.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_1.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("{{", part_1.?.event.TagMark.delimiter);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = reader.next();
    try testing.expect(part_2 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_2.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_2.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("}}", part_2.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 7), part_2.?.col);

    var part_3 = reader.next();
    try testing.expect(part_3 == null);
}

test "EOF custom tags" {
    const content = "[tag1]";

    var reader = Self.init(content, .{ .starting_delimiter = "[", .ending_delimiter = "]" });

    var part_1 = reader.next();
    try testing.expect(part_1 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_1.?.event);
    try testing.expectEqual(TagMarkType.Starting, part_1.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_1.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("[", part_1.?.event.TagMark.delimiter);
    try testing.expect(part_1.?.tail == null);
    try testing.expectEqual(@as(usize, 1), part_1.?.row);
    try testing.expectEqual(@as(usize, 1), part_1.?.col);

    var part_2 = reader.next();
    try testing.expect(part_2 != null);
    try testing.expectEqual(TextPart.Event.TagMark, part_2.?.event);
    try testing.expectEqual(TagMarkType.Ending, part_2.?.event.TagMark.tag_mark_type);
    try testing.expectEqual(DelimiterType.Regular, part_2.?.event.TagMark.delimiter_type);
    try testing.expectEqualStrings("]", part_2.?.event.TagMark.delimiter);
    try testing.expectEqualStrings("tag1", part_2.?.tail.?);
    try testing.expectEqual(@as(usize, 1), part_2.?.row);
    try testing.expectEqual(@as(usize, 6), part_2.?.col);

    var part_3 = reader.next();
    try testing.expect(part_3 == null);
}
