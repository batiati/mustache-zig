const std = @import("std");
const Allocator = std.mem.Allocator;
const trait = std.meta.trait;

const context = @import("context.zig");
const Escape = context.Escape;
const IndentationStack = context.IndentationStack;

const testing = std.testing;
const assert = std.debug.assert;

pub fn escapedWrite(
    writer: anytype,
    value: []const u8,
    escape: Escape,
    indentation: ?*const IndentationStack,
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
    indentation: ?*const IndentationStack,
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
    indentation: if (indented) *const IndentationStack else void,
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

                    written_bytes += try indentedWrite(writer, indentation);

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
            if (new_line) written_bytes += try indentedWrite(writer, indentation);
        }

        return written_bytes;
    } else {
        try writer.writeAll(value);
        return value.len;
    }
}

pub fn indentedWrite(writer: anytype, indentation: *const IndentationStack) !usize {
    var written_bytes: usize = 0;
    var current_level_indentation: ?*const IndentationStack = indentation;
    while (current_level_indentation) |level_indentation| {
        defer current_level_indentation = level_indentation.previous;

        try writer.writeAll(level_indentation.indentation);
        written_bytes += level_indentation.indentation.len;
    }

    return written_bytes;
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
    var indent_1 = IndentationStack{ .previous = null, .indentation = ">>" };

    try expectEscapeAndIndent("&gt;a\n>>&gt;b\n>>&gt;c", ">a\n>b\n>c", .Escaped, &indent_1);
    try expectEscapeAndIndent("&gt;a\r\n>>&gt;b\r\n>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, &indent_1);

    var indent_2 = IndentationStack{ .previous = &indent_1, .indentation = ">>" };

    try expectEscapeAndIndent("&gt;a\n>>>>&gt;b\n>>>>&gt;c", ">a\n>b\n>c", .Escaped, &indent_2);
    try expectEscapeAndIndent("&gt;a\r\n>>>>&gt;b\r\n>>>>&gt;c", ">a\r\n>b\r\n>c", .Escaped, &indent_2);
}

test "Indentation" {
    var indent_1 = IndentationStack{ .previous = null, .indentation = ">>" };

    try expectIndent("a\n>>b\n>>c", "a\nb\nc", &indent_1);
    try expectIndent("a\r\n>>b\r\n>>c", "a\r\nb\r\nc", &indent_1);

    var indent_2 = IndentationStack{ .previous = &indent_1, .indentation = ">>" };

    try expectIndent("a\n>>>>b\n>>>>c", "a\nb\nc", &indent_2);
    try expectIndent("a\r\n>>>>b\r\n>>>>c", "a\r\nb\r\nc", &indent_2);
}

fn expectEscape(expected: []const u8, value: []const u8, escape: Escape) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, escape, null);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}

fn expectIndent(expected: []const u8, value: []const u8, indentation: *IndentationStack) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, .Unescaped, indentation);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}

fn expectEscapeAndIndent(expected: []const u8, value: []const u8, escape: Escape, indentation: *IndentationStack) !void {
    const allocator = testing.allocator;
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    var written_bytes = try escapedWrite(list.writer(), value, escape, indentation);
    try testing.expectEqualStrings(expected, list.items);
    try testing.expectEqual(expected.len, written_bytes);
}
