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

const parsing = @import("parsing.zig");
const TextScanner = parsing.TextScanner;
const TrimmingIndex = parsing.TrimmingIndex;

const Self = @This();

// Simple state-machine to track left and right line breaks while scanning the text
const LeftLFState = union(enum) { Scanning, NotFound, Found: u32 };
const RightLFState = union(enum) { Waiting, NotFound, Found: u32 };

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
            assert(index >= self.text_scanner.block_index);
            const lf_index = @intCast(u32, index - self.text_scanner.block_index);

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

pub fn getLeftTrimmingIndex(self: Self) TrimmingIndex {
    return switch (self.left_lf) {
        .Scanning, .NotFound => .PreserveWhitespaces,
        .Found => |index| .{
            .AllowTrimming = .{
                .index = index,
                .stand_alone = true,
            },
        },
    };
}

pub fn getRightTrimmingIndex(self: Self) TrimmingIndex {
    return switch (self.right_lf) {
        .Waiting => blk: {

            // If there are only whitespaces, it can be trimmed right
            // It depends on the previous text block to be an standalone tag
            if (self.left_lf == .Scanning) {
                break :blk TrimmingIndex{
                    .AllowTrimming = .{
                        .index = 0,
                        .stand_alone = false,
                    },
                };
            } else {
                break :blk .PreserveWhitespaces;
            }
        },

        .NotFound => .PreserveWhitespaces,
        .Found => |index| TrimmingIndex{
            .AllowTrimming = .{
                .index = index + 1,
                .stand_alone = true,
            },
        },
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 7), block.?.right_trimming.AllowTrimming.index);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 9), block.?.right_trimming.AllowTrimming.index);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 11), block.?.right_trimming.AllowTrimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.left_trimming);
    try testing.expectEqualStrings("ABC\nABC\n  ", block.?.tail.?);

    block.?.trimRight();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.right_trimming);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 14), block.?.right_trimming.AllowTrimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.left_trimming);
    try testing.expectEqualStrings("ABC\r\nABC\r\n  ", block.?.tail.?);

    block.?.trimRight();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.right_trimming);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.right_trimming.AllowTrimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.left_trimming);
    try testing.expectEqualStrings("  ", block.?.tail.?);

    block.?.trimRight();
    try testing.expectEqual(TrimmingIndex.Trimmed, block.?.right_trimming);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 4), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "resolve" { // Tabs text trimming" {

    //                                     2   3
    //                                     ↓   ↓
    var text_scanner = TextScanner.init("\t\t\n\t\t");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\t\t\n\t\t", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Whitespace left trimming" {

    //                                     2 EOF
    //                                     ↓ ↓
    var text_scanner = TextScanner.init("  \n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Whitespace left trimming \\r\\n" {

    //                                       3 EOF
    //                                       ↓ ↓
    var text_scanner = TextScanner.init("  \r\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("  \r\n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.left_trimming.AllowTrimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Tabs left trimming" {

    //                                       2 EOF
    //                                       ↓ ↓
    var text_scanner = TextScanner.init("\t\t\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\t\t\n", block.?.tail.?);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.left_trimming.AllowTrimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 0), block.?.left_trimming.AllowTrimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 1), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 1), block.?.left_trimming.AllowTrimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 2), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
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
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 0), block.?.left_trimming.AllowTrimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 1), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Single line break" {

    //                                   0 EOF
    //                                   ↓ ↓
    var text_scanner = TextScanner.init("\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\n", block.?.tail.?);

    // Trim the line-break
    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 0), block.?.left_trimming.AllowTrimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Single line break \\r\\n" {

    //                                   0   EOF
    //                                   ↓   ↓
    var text_scanner = TextScanner.init("\r\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\r\n", block.?.tail.?);

    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 1), block.?.left_trimming.AllowTrimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "No trimming" {

    //
    //
    var text_scanner = TextScanner.init("   ABC\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\nABC   ", block.?.tail.?);

    // No trimming
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);
    try testing.expect(block.?.right_trimming == .PreserveWhitespaces);
}

test "No trimming, no whitespace" {

    //                                      EOF
    //                                      ↓
    var text_scanner = TextScanner.init("|\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("|\n", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "No trimming, no whitespace \\r\\n" {

    //                                        EOF
    //                                        ↓
    var text_scanner = TextScanner.init("|\r\n");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("|\r\n", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(block.?.tail.?.len, block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "No trimming \\r\\n" {

    //
    //
    var text_scanner = TextScanner.init("   ABC\r\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\r\nABC   ", block.?.tail.?);

    // No trimming both left and right
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);
    try testing.expect(block.?.right_trimming == .PreserveWhitespaces);
}

test "No whitespace" {

    //
    //
    var text_scanner = TextScanner.init("ABC");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("ABC", block.?.tail.?);

    // No trimming both left and right
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);
    try testing.expect(block.?.right_trimming == .PreserveWhitespaces);
}

test "Trimming left only" {

    //                                      3
    //                                      ↓
    var text_scanner = TextScanner.init("   \nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   \nABC   ", block.?.tail.?);

    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 3), block.?.left_trimming.AllowTrimming.index);

    // No trimming right
    try testing.expect(block.?.right_trimming == .PreserveWhitespaces);
}

test "Trimming left only \\r\\n" {

    //                                        4
    //                                        ↓
    var text_scanner = TextScanner.init("   \r\nABC   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   \r\nABC   ", block.?.tail.?);

    try testing.expect(block.?.left_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 4), block.?.left_trimming.AllowTrimming.index);

    // No trimming tight
    try testing.expect(block.?.right_trimming == .PreserveWhitespaces);
}

test "Trimming right only" {

    //                                           7
    //                                           ↓
    var text_scanner = TextScanner.init("   ABC\n   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\n   ", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 7), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Trimming right only \\r\\n" {

    //                                             8
    //                                             ↓
    var text_scanner = TextScanner.init("   ABC\r\n   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ABC\r\n   ", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 8), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(true, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Only whitespace" {

    //                                   0
    //                                   ↓
    var text_scanner = TextScanner.init("   ");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("   ", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    // Trim right from the begin can be allowed if the tag is stand-alone
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 0), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(false, block.?.right_trimming.AllowTrimming.stand_alone);
}

test "Only tabs" {

    //                                   0
    //                                   ↓
    var text_scanner = TextScanner.init("\t\t\t");

    var block = text_scanner.next();
    try testing.expect(block != null);
    try testing.expect(block.?.tail != null);
    try testing.expectEqualStrings("\t\t\t", block.?.tail.?);

    // No trimming left
    try testing.expect(block.?.left_trimming == .PreserveWhitespaces);

    // Trim right from the begin can be allowed if the tag is stand-alone
    try testing.expect(block.?.right_trimming == .AllowTrimming);
    try testing.expectEqual(@as(usize, 0), block.?.right_trimming.AllowTrimming.index);
    try testing.expectEqual(false, block.?.right_trimming.AllowTrimming.stand_alone);
}
