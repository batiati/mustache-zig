const std = @import("std");

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const assert = std.debug.assert;
const testing = std.testing;

pub const Delimiters = struct {
    pub const DefaultStartingDelimiter = "{{";
    pub const DefaultEndingDelimiter = "}}";

    starting_delimiter: []const u8 = DefaultStartingDelimiter,
    ending_delimiter: []const u8 = DefaultEndingDelimiter,
};

pub const PartType = enum(u8) {
    static_text,
    interpolation,
    comments = '!',
    section = '#',
    inverted_section = '^',
    close_section = '/',
    partial = '>',
    parent = '<',
    block = '$',
    no_escape = '&',
    delimiters = '=',
    triple_mustache = '{',

    pub fn canBeStandAlone(part_type: @This()) bool {
        return switch (part_type) {
            .static_text,
            .interpolation,
            .no_escape,
            .triple_mustache,
            => false,
            else => true,
        };
    }
};

pub fn TrimmingIndex(comptime options: TemplateOptions) type {
    return if (options.features.preseve_line_breaks_and_indentation)
        union(enum) {
            PreserveWhitespaces,
            AllowTrimming: struct {
                index: u32,
                stand_alone: bool,
            },
            Trimmed,
        }
    else
        enum { PreserveWhitespaces };
}

pub const IndexBookmark = struct {
    prev: ?*@This(),
    index: u32,
};

pub const Node = @import("node.zig").Node;
pub const TextPart = @import("text_part.zig").TextPart;
pub const TextScanner = @import("text_scanner.zig").TextScanner;
pub const Trimmer = @import("trimmer.zig").Trimmer;
pub const FileReader = @import("file_reader.zig").FileReader;
pub const Parser = @import("parser.zig").Parser;

test {
    _ = testing.refAllDecls(@This());
}
