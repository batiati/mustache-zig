const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const parsing = @import("parsing.zig");
const tokens = parsing.tokens;
const Event = parsing.Event;
const BlockType = parsing.BlockType;
const Mark = parsing.Mark;
const MarkType = parsing.MarkType;
const DelimiterType = parsing.DelimiterType;
const Delimiters = parsing.Delimiters;
const TrimmingIndex = parsing.TrimmingIndex;

const Self = @This();

event: Event,
tail: ?[]const u8,
row: u32,
col: u32,
left_trimming: TrimmingIndex = .PreserveWhitespaces,
right_trimming: TrimmingIndex = .PreserveWhitespaces,
indentation: ?[]const u8 = null,

pub fn readBlockType(self: *Self) ?BlockType {
    if (self.tail) |tail| {
        const match: ?BlockType = switch (tail[0]) {
            tokens.Comments => .Comment,
            tokens.Section => .Section,
            tokens.InvertedSection => .InvertedSection,
            tokens.Partial => .Partial,
            tokens.Parent => .Parent,
            tokens.Block => .Block,
            tokens.Delimiters => .Delimiters,
            tokens.NoEscape => .NoScapeInterpolation,
            tokens.CloseSection => .CloseSection,
            else => null,
        };

        if (match) |block_type| {
            self.tail = tail[1..];
            return block_type;
        }
    }

    return null;
}

pub fn trimRight(self: *Self) void {
    switch (self.right_trimming) {
        .PreserveWhitespaces, .Trimmed => {},
        .AllowTrimming => |right_trimming| {
            if (self.tail) |tail| {
                if (right_trimming.index == 0) {
                    self.tail = null;
                } else if (right_trimming.index < tail.len) {
                    self.tail = tail[0..right_trimming.index];
                }

                if (right_trimming.index >= tail.len - 1) {
                    self.indentation = null;
                } else {
                    self.indentation = tail[right_trimming.index..];
                }
            }

            self.right_trimming = .Trimmed;
        },
    }
}

pub fn trimLeft(self: *Self) void {
    switch (self.left_trimming) {
        .PreserveWhitespaces, .Trimmed => {},
        .AllowTrimming => |left_trimming| {
            if (self.tail) |tail| {

                // Update the trim-right index and indentation after trimming left
                // BEFORE:
                //                 2      7
                //                 ↓      ↓
                //const value = "  \nABC\n  "
                //
                // AFTER:
                //                    4
                //                    ↓
                //const value = "ABC\n  "

                switch (self.right_trimming) {
                    .AllowTrimming => |right_trimming| {
                        self.right_trimming = .{
                            .AllowTrimming = .{
                                .index = right_trimming.index - left_trimming.index - 1,
                                .stand_alone = right_trimming.stand_alone,
                            },
                        };
                    },

                    else => {},
                }

                if (left_trimming.index >= tail.len - 1) {
                    self.tail = null;
                } else {
                    self.tail = tail[left_trimming.index + 1 ..];
                }
            }

            self.left_trimming = .Trimmed;
        },
    }
}
