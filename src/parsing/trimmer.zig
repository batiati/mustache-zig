/// Implements mustache's trim logic
/// Line breaks and whitespace standing between "stand-alone" tags must be trimmed
///
/// Example
/// const template = "  {{#section}}\nName\n  {{#section}}\n"
/// Should render only "Name\n"
const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const parsing = @import("parsing.zig");

pub fn Trimmer(comptime TextScanner: type, comptime TrimmingIndex: type) type {
    return if (@typeInfo(TrimmingIndex) == .Union)
        struct {
            const Self = @This();

            // Simple state-machine to track left and right line breaks while scanning the text
            const LeftLFState = union(enum) { scanning, not_found, found: u32 };
            const RightLFState = union(enum) { waiting, not_found, found: u32 };

            const Chars = struct {
                pub const cr = '\r';
                pub const lf = '\n';
                pub const tab = '\t';
                pub const space = ' ';
                pub const null_char = '\x00';
            };

            text_scanner: *const TextScanner,
            has_pending_cr: bool = false,
            left_lf: LeftLFState = .scanning,
            right_lf: RightLFState = .waiting,

            pub fn init(text_scanner: *TextScanner) Self {
                return .{
                    .text_scanner = text_scanner,
                };
            }

            pub fn move(self: *Self) void {
                const index = self.text_scanner.index;
                const char = self.text_scanner.content[index];

                if (char != Chars.lf) {
                    self.has_pending_cr = (char == Chars.cr);
                }

                switch (char) {
                    Chars.cr, Chars.space, Chars.tab, Chars.null_char => {},
                    Chars.lf => {
                        assert(index >= self.text_scanner.block_index);
                        const lf_index: u32 = @intCast(index - self.text_scanner.block_index);

                        if (self.left_lf == .scanning) {
                            self.left_lf = .{ .found = lf_index };
                            self.right_lf = .{ .found = lf_index };
                        } else if (self.right_lf != .waiting) {
                            self.right_lf = .{ .found = lf_index };
                        }
                    },
                    else => {
                        if (self.left_lf == .scanning) {
                            self.left_lf = .not_found;
                            self.right_lf = .not_found;
                        } else if (self.right_lf != .waiting) {
                            self.right_lf = .not_found;
                        }
                    },
                }
            }

            pub fn getLeftTrimmingIndex(self: Self) TrimmingIndex {
                return switch (self.left_lf) {
                    .scanning, .not_found => .preserve_whitespaces,
                    .found => |index| .{
                        .allow_trimming = .{
                            .index = index,
                            .stand_alone = true,
                        },
                    },
                };
            }

            pub fn getRightTrimmingIndex(self: Self) TrimmingIndex {
                return switch (self.right_lf) {
                    .waiting => blk: {

                        // If there are only whitespaces, it can be trimmed right
                        // It depends on the previous text block to be an standalone tag
                        if (self.left_lf == .scanning) {
                            break :blk TrimmingIndex{
                                .allow_trimming = .{
                                    .index = 0,
                                    .stand_alone = false,
                                },
                            };
                        } else {
                            break :blk .preserve_whitespaces;
                        }
                    },

                    .not_found => .preserve_whitespaces,
                    .found => |index| TrimmingIndex{
                        .allow_trimming = .{
                            .index = index + 1,
                            .stand_alone = true,
                        },
                    },
                };
            }
        }
    else
        struct {
            const Self = @This();

            pub inline fn init(text_scanner: *TextScanner) Self {
                _ = text_scanner;
                return .{};
            }

            pub inline fn move(self: *Self) void {
                _ = self;
            }

            pub inline fn getLeftTrimmingIndex(self: Self) TrimmingIndex {
                _ = self;
                return .preserve_whitespaces;
            }

            pub inline fn getRightTrimmingIndex(self: Self) TrimmingIndex {
                _ = self;
                return .preserve_whitespaces;
            }
        };
}

const testing_options = TemplateOptions{
    .source = .{ .string = .{} },
    .output = .render,
};
const Node = parsing.Node(testing_options);
const TestingTextScanner = parsing.TextScanner(Node, testing_options);
const TestingTrimmingIndex = parsing.TrimmingIndex(testing_options);

test "Line breaks" {
    const allocator = testing.allocator;

    //                                                2      7
    //                                                ↓      ↓
    var text_scanner = try TestingTextScanner.init("  \nABC\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \nABC\n  ", block.?.content.slice);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 7), block.?.trimming.right.allow_trimming.index);
}

test "Line breaks \\r\\n" {
    const allocator = testing.allocator;

    //                                                  3        9
    //                                                  ↓        ↓
    var text_scanner = try TestingTextScanner.init("  \r\nABC\r\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \r\nABC\r\n  ", block.?.content.slice);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 9), block.?.trimming.right.allow_trimming.index);
}

test "Multiple line breaks" {
    const allocator = testing.allocator;

    //                                                2           11
    //                                                ↓           ↓
    var text_scanner = try TestingTextScanner.init("  \nABC\nABC\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \nABC\nABC\n  ", block.?.content.slice);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 11), block.?.trimming.right.allow_trimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.left);
    try testing.expectEqualStrings("ABC\nABC\n  ", block.?.content.slice);

    var indentation = block.?.trimRight();
    try testing.expect(indentation != null);
    try testing.expectEqualStrings("  ", indentation.?.slice);

    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.right);
    try testing.expectEqualStrings("ABC\nABC\n", block.?.content.slice);
}

test "Multiple line breaks \\r\\n" {
    const allocator = testing.allocator;

    //                                                  3               14
    //                                                  ↓               ↓
    var text_scanner = try TestingTextScanner.init("  \r\nABC\r\nABC\r\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \r\nABC\r\nABC\r\n  ", block.?.content.slice);

    // Trim all white-spaces, including the first line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the last line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 14), block.?.trimming.right.allow_trimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.left);
    try testing.expectEqualStrings("ABC\r\nABC\r\n  ", block.?.content.slice);

    var indentation = block.?.trimRight();
    try testing.expect(indentation != null);
    try testing.expectEqualStrings("  ", indentation.?.slice);

    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.right);
    try testing.expectEqualStrings("ABC\r\nABC\r\n", block.?.content.slice);
}

test "Whitespace text trimming" {
    const allocator = testing.allocator;
    //                                                2 3
    //                                                ↓ ↓
    var text_scanner = try TestingTextScanner.init("  \n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \n  ", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.right.allow_trimming.index);

    block.?.trimLeft();
    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.left);
    try testing.expectEqualStrings("  ", block.?.content.slice);

    var indentation = block.?.trimRight();
    try testing.expect(indentation != null);
    try testing.expectEqualStrings("  ", indentation.?.slice);

    try testing.expectEqual(TestingTrimmingIndex.trimmed, block.?.trimming.right);
    try testing.expect(block.?.content.slice.len == 0);
}

test "Whitespace text trimming \\r\\n" {
    const allocator = testing.allocator;

    //                                                  3 4
    //                                                  ↓ ↓
    var text_scanner = try TestingTextScanner.init("  \r\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \r\n  ", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 4), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Tabs text trimming" {
    const allocator = testing.allocator;

    //                                                2   3
    //                                                ↓   ↓
    var text_scanner = try TestingTextScanner.init("\t\t\n\t\t");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\t\t\n\t\t", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Trim all white-spaces, after the line break
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Whitespace left trimming" {
    const allocator = testing.allocator;

    //                                                2 EOF
    //                                                ↓ ↓
    var text_scanner = try TestingTextScanner.init("  \n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \n", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Whitespace left trimming \\r\\n" {
    const allocator = testing.allocator;

    //                                                  3 EOF
    //                                                  ↓ ↓
    var text_scanner = try TestingTextScanner.init("  \r\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("  \r\n", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.left.allow_trimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Tabs left trimming" {
    const allocator = testing.allocator;

    //                                                  2 EOF
    //                                                  ↓ ↓
    var text_scanner = try TestingTextScanner.init("\t\t\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\t\t\n", block.?.content.slice);

    // Trim all white-spaces, including the line break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.left.allow_trimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Whitespace right trimming" {
    const allocator = testing.allocator;

    //                                              0 1
    //                                              ↓ ↓
    var text_scanner = try TestingTextScanner.init("\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\n  ", block.?.content.slice);

    // line break belongs to the left side
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 0), block.?.trimming.left.allow_trimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 1), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Whitespace right trimming \\r\\n" {
    const allocator = testing.allocator;

    //                                               1 2
    //                                               ↓ ↓
    var text_scanner = try TestingTextScanner.init("\r\n  ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\r\n  ", block.?.content.slice);

    // line break belongs to the left side
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 1), block.?.trimming.left.allow_trimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 2), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Tabs right trimming" {
    const allocator = testing.allocator;

    //                                              0 1
    //                                              ↓ ↓
    var text_scanner = try TestingTextScanner.init("\n\t\t");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\n\t\t", block.?.content.slice);

    // line break belongs to the left side
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 0), block.?.trimming.left.allow_trimming.index);

    // only white-spaces on the right side
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 1), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Single line break" {
    const allocator = testing.allocator;

    //                                              0 EOF
    //                                              ↓ ↓
    var text_scanner = try TestingTextScanner.init("\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\n", block.?.content.slice);

    // Trim the line-break
    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 0), block.?.trimming.left.allow_trimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Single line break \\r\\n" {
    const allocator = testing.allocator;

    //                                              0   EOF
    //                                              ↓   ↓
    var text_scanner = try TestingTextScanner.init("\r\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\r\n", block.?.content.slice);

    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 1), block.?.trimming.left.allow_trimming.index);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "No trimming" {
    const allocator = testing.allocator;

    var text_scanner = try TestingTextScanner.init("   ABC\nABC   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   ABC\nABC   ", block.?.content.slice);

    // No trimming
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);
    try testing.expect(block.?.trimming.right == .preserve_whitespaces);
}

test "No trimming, no whitespace" {
    const allocator = testing.allocator;

    //                                                 EOF
    //                                                 ↓
    var text_scanner = try TestingTextScanner.init("|\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("|\n", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "No trimming, no whitespace \\r\\n" {
    const allocator = testing.allocator;

    //                                                   EOF
    //                                                   ↓
    var text_scanner = try TestingTextScanner.init("|\r\n");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("|\r\n", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    // Nothing to trim right (index == len)
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(block.?.content.slice.len, block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "No trimming \\r\\n" {
    const allocator = testing.allocator;

    var text_scanner = try TestingTextScanner.init("   ABC\r\nABC   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   ABC\r\nABC   ", block.?.content.slice);

    // No trimming both left and right
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);
    try testing.expect(block.?.trimming.right == .preserve_whitespaces);
}

test "No whitespace" {
    const allocator = testing.allocator;

    //
    //
    var text_scanner = try TestingTextScanner.init("ABC");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("ABC", block.?.content.slice);

    // No trimming both left and right
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);
    try testing.expect(block.?.trimming.right == .preserve_whitespaces);
}

test "Trimming left only" {
    const allocator = testing.allocator;

    //                                                 3
    //                                                 ↓
    var text_scanner = try TestingTextScanner.init("   \nABC   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   \nABC   ", block.?.content.slice);

    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 3), block.?.trimming.left.allow_trimming.index);

    // No trimming right
    try testing.expect(block.?.trimming.right == .preserve_whitespaces);
}

test "Trimming left only \\r\\n" {
    const allocator = testing.allocator;

    //                                                   4
    //                                                   ↓
    var text_scanner = try TestingTextScanner.init("   \r\nABC   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   \r\nABC   ", block.?.content.slice);

    try testing.expect(block.?.trimming.left == .allow_trimming);
    try testing.expectEqual(@as(usize, 4), block.?.trimming.left.allow_trimming.index);

    // No trimming tight
    try testing.expect(block.?.trimming.right == .preserve_whitespaces);
}

test "Trimming right only" {
    const allocator = testing.allocator;

    //                                                     7
    //                                                     ↓
    var text_scanner = try TestingTextScanner.init("   ABC\n   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   ABC\n   ", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 7), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Trimming right only \\r\\n" {
    const allocator = testing.allocator;

    //                                                       8
    //                                                       ↓
    var text_scanner = try TestingTextScanner.init("   ABC\r\n   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   ABC\r\n   ", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 8), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(true, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Only whitespace" {
    const allocator = testing.allocator;

    //                                             0
    //                                             ↓
    var text_scanner = try TestingTextScanner.init("   ");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("   ", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    // Trim right from the begin can be allowed if the tag is stand-alone
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 0), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(false, block.?.trimming.right.allow_trimming.stand_alone);
}

test "Only tabs" {
    const allocator = testing.allocator;

    //                                              0
    //                                              ↓
    var text_scanner = try TestingTextScanner.init("\t\t\t");
    defer text_scanner.deinit(allocator);

    try text_scanner.setDelimiters(.{});

    var block = try text_scanner.next(allocator);
    try testing.expect(block != null);
    try testing.expectEqualStrings("\t\t\t", block.?.content.slice);

    // No trimming left
    try testing.expect(block.?.trimming.left == .preserve_whitespaces);

    // Trim right from the begin can be allowed if the tag is stand-alone
    try testing.expect(block.?.trimming.right == .allow_trimming);
    try testing.expectEqual(@as(usize, 0), block.?.trimming.right.allow_trimming.index);
    try testing.expectEqual(false, block.?.trimming.right.allow_trimming.stand_alone);
}
