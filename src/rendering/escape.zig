const std = @import("std");
const Allocator = std.mem.Allocator;
const trait = std.meta.trait;

const context = @import("context.zig");
const Escape = context.Escape;
const Indentation = context.Indentation;
const IndentationQueue = context.IndentationQueue;

const testing = std.testing;
const assert = std.debug.assert;

pub fn escapedWrite(
    writer: anytype,
    value: []const u8,
    escape: Escape,
    indentation: ?Indentation,
) @TypeOf(writer).Error!usize {

    // Avoid too many runtime comparations inside the loop, by epecializing versions of the same function at comptime

    return switch (escape) {
        .Escaped => if (indentation) |indentation_stack|
            write(true, true, writer, indentation_stack, value)
        else
            write(true, false, writer, {}, value),
        .Unescaped => if (indentation) |indentation_stack|
            write(false, true, writer, indentation_stack, value)
        else
            write(false, false, writer, {}, value),
    };
}

pub fn unescapedWrite(
    writer: anytype,
    value: []const u8,
    indentation: ?Indentation,
) @TypeOf(writer).Error!usize {

    // Avoid too many runtime comparations inside the loop, by epecializing versions of the same function at comptime
    return if (indentation) |indentation_stack|
        write(false, true, writer, indentation_stack, value)
    else
        write(false, false, writer, {}, value);
}

fn write(
    comptime escaped: bool,
    comptime indented: bool,
    writer: anytype,
    indentation: if (indented) Indentation else void,
    value: []const u8,
) @TypeOf(writer).Error!usize {
    if (comptime escaped or indented) {
        const @"null" = '\x00';
        const html_null: []const u8 = "\u{fffd}";

        var index: usize = 0;
        var written_bytes: usize = 0;
        var new_line: if (indented) bool else void = if (indented) false else {};

        var char_index: usize = 0;
        while (char_index < value.len) : (char_index += 1) {
            const char = value[char_index];

            if (comptime indented) {

                // The indentation must be inserted after the line break
                // Supports both \n and \r\n

                if (new_line) {
                    defer new_line = false;

                    if (char_index > index) {
                        const slice = value[index..char_index];
                        try writer.writeAll(slice);
                        written_bytes += slice.len;
                    }

                    written_bytes += try indentation.write(.Middle, writer);

                    index = char_index;
                } else if (char == '\n') {
                    new_line = true;
                    continue;
                }
            }

            if (comptime escaped) {
                const replace = switch (char) {
                    '"' => "&quot;",
                    '\'' => "&#39;",
                    '&' => "&amp;",
                    '<' => "&lt;",
                    '>' => "&gt;",
                    @"null" => html_null,
                    else => continue,
                };

                if (char_index > index) {
                    const slice = value[index..char_index];
                    try writer.writeAll(slice);
                    written_bytes += slice.len;
                }

                try writer.writeAll(replace);
                written_bytes += replace.len;

                index = char_index + 1;
            }
        }

        if (index < value.len) {
            const slice = value[index..];
            try writer.writeAll(slice);
            written_bytes += slice.len;
        }

        if (comptime indented) {
            if (new_line) written_bytes += try indentation.write(.Last, writer);
        }

        return written_bytes;
    } else {
        try writer.writeAll(value);
        return value.len;
    }
}

test "Escape" {
    try expectEscape("&gt;abc", ">abc", .Escaped);
    try expectEscape("abc&lt;", "abc<", .Escaped);
    try expectEscape("&gt;abc&lt;", ">abc<", .Escaped);
    try expectEscape("ab&amp;cd", "ab&cd", .Escaped);
    try expectEscape("&gt;ab&amp;cd", ">ab&cd", .Escaped);
    try expectEscape("ab&amp;cd&lt;", "ab&cd<", .Escaped);
    try expectEscape("&gt;ab&amp;cd&lt;", ">ab&cd<", .Escaped);
    try expectEscape("&quot;ab&#39;&amp;&#39;cd&quot;",
        \\"ab'&'cd"
    , .Escaped);

    try expectEscape(">ab&cd<", ">ab&cd<", .Unescaped);
}

test "Escape and Indentation" {
    var root = IndentationQueue{};

    var node_1 = IndentationQueue.Node{
        .indentation = ">>",
        .last_indented_element = undefined,
    };
    var level_1 = root.indent(&node_1);

    try expectEscapeAndIndent("&gt;a\n>>&gt;b\n>>&gt;c", ">a\n>b\n>c", .Escaped, level_1.get(undefined));
    try expectEscapeAndIndent("&gt;a\r\n>>&gt;b\r\n>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_1.get(undefined));

    {
        var node_2 = IndentationQueue.Node{
            .indentation = ">>",
            .last_indented_element = undefined,
        };
        var level_2 = level_1.indent(&node_2);
        defer level_1.unindent();

        try expectEscapeAndIndent("&gt;a\n>>>>&gt;b\n>>>>&gt;c", ">a\n>b\n>c", .Escaped, level_2.get(undefined));
        try expectEscapeAndIndent("&gt;a\r\n>>>>&gt;b\r\n>>>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_2.get(undefined));
    }

    try expectEscapeAndIndent("&gt;a\n>>&gt;b\n>>&gt;c", ">a\n>b\n>c", .Escaped, level_1.get(undefined));
    try expectEscapeAndIndent("&gt;a\r\n>>&gt;b\r\n>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, level_1.get(undefined));
}

test "Indentation" {
    var root = IndentationQueue{};

    var node_1 = IndentationQueue.Node{
        .indentation = ">>",
        .last_indented_element = undefined,
    };
    var level_1 = root.indent(&node_1);

    try expectIndent("a\n>>b\n>>c", "a\nb\nc", level_1.get(undefined));
    try expectIndent("a\r\n>>b\r\n>>c", "a\r\nb\r\nc", level_1.get(undefined));

    {
        var node_2 = IndentationQueue.Node{
            .indentation = ">>",
            .last_indented_element = undefined,
        };
        var level_2 = level_1.indent(&node_2);
        defer level_1.unindent();

        try expectIndent("a\n>>>>b\n>>>>c", "a\nb\nc", level_2.get(undefined));
        try expectIndent("a\r\n>>>>b\r\n>>>>c", "a\r\nb\r\nc", level_2.get(undefined));
    }

    try expectIndent("a\n>>b\n>>c", "a\nb\nc", level_1.get(undefined));
    try expectIndent("a\r\n>>b\r\n>>c", "a\r\nb\r\nc", level_1.get(undefined));
}

fn expectEscape(expected: []const u8, value: []const u8, escape: Escape) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, escape, null);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}

fn expectIndent(expected: []const u8, value: []const u8, indentation: ?Indentation) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, .Unescaped, indentation);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}

fn expectEscapeAndIndent(expected: []const u8, value: []const u8, escape: Escape, indentation: ?Indentation) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, escape, indentation);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}
