///
/// Implements mustache's trim logic
/// Line breaks and whitespace standing between "stand-alone" tags must be trimmed
///
/// Example
/// const template = "  {{#section}}\nName\n  {{#section}}\n"
/// Should render only "Name\n"
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const scanner = @import("scanner.zig");
const TextScanner = scanner.TextScanner;

const Self = @This();

// Simple state-machine to track left and right line breaks while scanning the text
const LeftLFState = union(enum) { Scanning, NotFound, Found: usize };
const RightLFState = union(enum) { Waiting, NotFound, Found: usize };

// Line break and whitespace characters
const CR = '\r';
const LF = '\n';
const TAB = '\t';
const SPACE = ' ';
const NULL = '\x00';

text_scanner: *const TextScanner,
has_pending_cr: bool = false,
left_lf: LeftLFState = .Scanning,
right_lf: RightLFState = .Waiting,

pub fn move(self: *Self) void {
    const index = self.text_scanner.index;
    const char = self.text_scanner.content[index];

    if (char != LF) {
        self.has_pending_cr = (char == CR);
    }

    switch (char) {
        CR, SPACE, TAB, NULL => {},
        LF => {
            const lf_index = index - self.text_scanner.block_index;

            assert(lf_index >= 0);

            if (self.left_lf == .Scanning) {
                self.left_lf = .{ .Found = lf_index };
                self.right_lf = .{ .Found = lf_index };
            } else if (self.right_lf != .Waiting) {
                self.right_lf = .{ .Found = lf_index };
            }
        },
        else => {
            if (self.left_lf == .Scanning) {
                self.left_lf = .NotFound;
                self.right_lf = .NotFound;
            } else if (self.right_lf != .Waiting) {
                self.right_lf = .NotFound;
            }
        },
    }
}

pub fn getLeftIndex(self: Self) ?usize {
    return switch (self.left_lf) {
        .Scanning => self.text_scanner.index,
        .Found => |index| index,
        .NotFound => null,
    };
}

pub fn getRightIndex(self: Self) ?usize {
    return switch (self.right_lf) {
        .Waiting, .NotFound => null,
        .Found => |index| if (index == self.text_scanner.index) null else index + 1,
    };
}

test "Line breaks" {

    //                                     2      7
    //                                     ↓      ↓
    var text_scanner = TextScanner.init("  \nABC\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \nABC\n  ", block.?.tail.?);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 7), block.?.trim_right_index.?);
}

test "Line breaks \\r\\n" {

    //                                       3        9
    //                                       ↓        ↓
    var text_scanner = TextScanner.init("  \r\nABC\r\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \r\nABC\r\n  ", block.?.tail.?);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_left_index.?);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 9), block.?.trim_right_index.?);
}

test "Multiple line breaks" {

    //                                     2           11
    //                                     ↓           ↓
    var text_scanner = TextScanner.init("  \nABC\nABC\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \nABC\nABC\n  ", block.?.tail.?);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 11), block.?.trim_right_index.?);

    try testing.expectEqual(true, block.?.trimLeft());
    try testing.expectEqualStrings("ABC\nABC\n  ", block.?.tail.?);

    try testing.expectEqual(true, block.?.trimRight());
    try testing.expectEqualStrings("ABC\nABC\n", block.?.tail.?);

}

test "Multiple line breaks \\r\\n" {

    //                                       3               14
    //                                       ↓               ↓
    var text_scanner = TextScanner.init("  \r\nABC\r\nABC\r\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \r\nABC\r\nABC\r\n  ", block.?.tail.?);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_left_index.?);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 14), block.?.trim_right_index.?);

    try testing.expectEqual(true, block.?.trimLeft());
    try testing.expectEqualStrings("ABC\r\nABC\r\n  ", block.?.tail.?);

    try testing.expectEqual(true, block.?.trimRight());
    try testing.expectEqualStrings("ABC\r\nABC\r\n", block.?.tail.?);    
}

test "Whitespace text trimming" {

    //                                     2 3
    //                                     ↓ ↓
    var text_scanner = TextScanner.init("  \n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \n  ", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_right_index.?);

    try testing.expectEqual(true, block.?.trimLeft());
    try testing.expectEqualStrings("  ", block.?.tail.?);

    try testing.expectEqual(true, block.?.trimRight());
    try testing.expect(block.?.tail == null);        
}

test "Whitespace text trimming \\r\\n" {

    //                                       3 4
    //                                       ↓ ↓
    var text_scanner = TextScanner.init("  \r\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \r\n  ", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_left_index.?);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 4), block.?.trim_right_index.?);
}

test "Tabs text trimming" {

    //                                     2   3
    //                                     ↓   ↓
    var text_scanner = TextScanner.init("\t\t\n\t\t");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\t\t\n\t\t", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_right_index.?);
}

test "Whitespace left trimming" {

    //                                     2
    //                                     ↓
    var text_scanner = TextScanner.init("  \n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Nothing to trim right
    try testing.expect(block.?.trim_right_index == null);
}

test "Whitespace left trimming \\r\\n" {

    //                                       3
    //                                       ↓
    var text_scanner = TextScanner.init("  \r\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \r\n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_left_index.?);

    // Nothing to trim right
    try testing.expect(block.?.trim_right_index == null);
}

test "Tabs left trimming" {

    //                                       2
    //                                       ↓
    var text_scanner = TextScanner.init("\t\t\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\t\t\n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_left_index.?);

    // Nothing to trim right
    try testing.expect(block.?.trim_right_index == null);
}

test "Whitespace right trimming" {

    //                                   0 1
    //                                   ↓ ↓
    var text_scanner = TextScanner.init("\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\n  ", block.?.tail.?);

    // line break belongs to the left side
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 0), block.?.trim_left_index.?);

    // only white-spaces on the right side
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 1), block.?.trim_right_index.?);
}

test "Whitespace right trimming \\r\\n" {

    //                                     1 2
    //                                     ↓ ↓
    var text_scanner = TextScanner.init("\r\n  ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\r\n  ", block.?.tail.?);

    // line break belongs to the left side
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 1), block.?.trim_left_index.?);

    // only white-spaces on the right side
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 2), block.?.trim_right_index.?);
}

test "Tabs right trimming" {

    //                                   0 1
    //                                   ↓ ↓
    var text_scanner = TextScanner.init("\n\t\t");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\n\t\t", block.?.tail.?);

    // line break belongs to the left side
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 0), block.?.trim_left_index.?);

    // only white-spaces on the right side
    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 1), block.?.trim_right_index.?);
}

test "Single line break" {

    //                                   0
    //                                   ↓
    var text_scanner = TextScanner.init("\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\n", block.?.tail.?);

    // Trim the line-break
    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 0), block.?.trim_left_index.?);

    // Nothing to trim right
    try testing.expect(block.?.trim_right_index == null);
}

test "Single line break \\r\\n" {

    //                                   0
    //                                   ↓
    var text_scanner = TextScanner.init("\r\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\r\n", block.?.tail.?);

    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 1), block.?.trim_left_index.?);

    try testing.expect(block.?.trim_right_index == null);
}

test "No trimming" {

    //
    //
    var text_scanner = TextScanner.init("   ABC\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\nABC   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index == null);
    try testing.expect(block.?.trim_right_index == null);
}

test "No trimming \\r\\n" {

    //
    //
    var text_scanner = TextScanner.init("   ABC\r\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\r\nABC   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index == null);
    try testing.expect(block.?.trim_right_index == null);
}

test "No whitespace" {

    //
    //
    var text_scanner = TextScanner.init("ABC");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("ABC", block.?.tail.?);

    try testing.expect(block.?.trim_left_index == null);
    try testing.expect(block.?.trim_right_index == null);
}

test "Trimming left only" {

    //                                      3
    //                                      ↓
    var text_scanner = TextScanner.init("   \nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   \nABC   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 3), block.?.trim_left_index.?);

    try testing.expect(block.?.trim_right_index == null);
}

test "Trimming left only \\r\\n" {

    //                                        4
    //                                        ↓
    var text_scanner = TextScanner.init("   \r\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   \r\nABC   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index != null);
    try testing.expectEqual(@as(usize, 4), block.?.trim_left_index.?);

    try testing.expect(block.?.trim_right_index == null);
}

test "Trimming right only" {

    //                                           7
    //                                           ↓
    var text_scanner = TextScanner.init("   ABC\n   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\n   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index == null);

    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 7), block.?.trim_right_index.?);
}

test "Trimming right only \\r\\n" {

    //                                             8
    //                                             ↓
    var text_scanner = TextScanner.init("   ABC\r\n   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\r\n   ", block.?.tail.?);

    try testing.expect(block.?.trim_left_index == null);

    try testing.expect(block.?.trim_right_index != null);
    try testing.expectEqual(@as(usize, 8), block.?.trim_right_index.?);
}
