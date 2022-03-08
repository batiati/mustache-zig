///
/// TextBlock is some slice of string containing information about how it appears on the template source.
/// Each TextBlock is produced by the TextScanner, it is the first stage of the parsing process, 
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
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

const RefCounter = @import("../mem.zig").RefCounter;

const Self = @This();

///
/// The event that generated this TextBlock, 
/// It can be a text mark such {{ or }}, or a EOF
event: Event,

///
/// The tail slice from the last event until now
tail: ?[]const u8,

///
/// A ref counter for the buffer that holds this strings
ref_counter: RefCounter,

///
/// The line on the template source
/// Used mostly for error messages
lin: u32,

///
/// The column on the template source
/// Used mostly for error messages
col: u32,

///
/// Trimming rules for the left side of the slice
left_trimming: TrimmingIndex = .PreserveWhitespaces,

///
/// Trimming rules for the right side of the slice
right_trimming: TrimmingIndex = .PreserveWhitespaces,

///
/// Indentation presented on this text block
/// All indentation must be propagated to the child elements
indentation: ?[]const u8 = null,

pub inline fn deinit(self: *Self, allocator: Allocator) void {
    self.ref_counter.free(allocator);
}

///
/// Matches the BlockType
/// Can move 1 position ahead on the slice if this block contains a staring symbol as such ! # ^ & $ > < = / 
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
            tokens.NoEscape => .UnescapedInterpolation,
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

///
/// Processes the trimming rules for the right side of the slice
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

///
/// Processes the trimming rules for the left side of the slice
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

///
/// Matches the BlockType produced so far
pub fn matchBlockType(self: *Self) ?BlockType {
    switch (self.event) {
        .Mark => |tag_mark| {
            switch (tag_mark.mark_type) {
                .Starting => {

                    // If there is no current action, any content is a static text
                    if (self.tail != null) {
                        return .StaticText;
                    }
                },

                .Ending => {
                    const is_triple_mustache = tag_mark.delimiter_type == .NoScapeDelimiter;
                    if (is_triple_mustache) {
                        return .UnescapedInterpolation;
                    } else {

                        // Consider "interpolation" if there is none of the tagType indication (!, #, ^, >, <, $, =, &, /)
                        return self.readBlockType() orelse .Interpolation;
                    }
                },
            }
        },
        .Eof => {
            if (self.tail != null) {
                return .StaticText;
            }
        },
    }

    return null;
}
