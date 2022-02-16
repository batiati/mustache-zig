/// A simple text iterator
/// It just scans for the next delimiter or EOF.
const std = @import("std");
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;

const scanner = @import("scanner.zig");
const tokens = scanner.tokens;
const Event = scanner.Event;
const PartType = scanner.PartType;
const Mark = scanner.Mark;
const MarkType = scanner.MarkType;
const DelimiterType = scanner.DelimiterType;

const Self = @This();

event: Event,
tail: ?[]const u8,
row: usize,
col: usize,

pub fn readPartType(self: *Self) ?PartType {
    if (self.tail) |tail| {
        const match: ?PartType = switch (tail[0]) {
            tokens.Comments => .Comment,
            tokens.Section => .Section,
            tokens.InvertedSection => .InvertedSection,
            tokens.Partials => .Partials,
            tokens.Inheritance => .Inheritance,
            tokens.Delimiters => .Delimiters,
            tokens.NoEscape => .NoScapeInterpolation,
            tokens.CloseSection => .CloseSection,
            else => null,
        };

        if (match) |part_type| {
            self.tail = tail[1..];
            return part_type;
        }
    }

    return null;
}

pub fn trimStandAlone(self: *Self, trim: enum { Left, Right }) void {
    if (self.tail) |tail| {
        if (tail.len > 0) {
            switch (trim) {
                .Left => {
                    var index: usize = 0;
                    while (index < tail.len) : (index += 1) {
                        switch (tail[index]) {
                            ' ', '\t' => {},
                            '\r', '\n' => {
                                self.tail = if (index == tail.len - 1) null else tail[index + 1 ..];
                                return;
                            },
                            else => return,
                        }
                    }
                },

                .Right => {
                    var index: usize = 0;
                    while (index < tail.len) : (index += 1) {
                        const end = tail.len - index - 1;
                        switch (tail[end]) {
                            ' ', '\t' => {},
                            '\r', '\n' => {
                                self.tail = if (end == tail.len) null else tail[0 .. end + 1];
                                return;
                            },
                            else => return,
                        }
                    }
                },
            }
        }

        // Empty or white space is represented as "null"
        self.tail = null;
    }
}
