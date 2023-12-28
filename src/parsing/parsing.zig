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
    unescaped_interpolation = '&',
    delimiters = '=',
    triple_mustache = '{',

    pub fn canBeStandAlone(part_type: @This()) bool {
        return switch (part_type) {
            .static_text,
            .interpolation,
            .unescaped_interpolation,
            .triple_mustache,
            => false,
            else => true,
        };
    }
};

pub fn TrimmingIndexType(comptime options: TemplateOptions) type {
    return if (options.features.preseve_line_breaks_and_indentation)
        union(enum) {
            preserve_whitespaces,
            allow_trimming: struct {
                index: u32,
                stand_alone: bool,
            },
            trimmed,
        }
    else
        enum { preserve_whitespaces };
}

pub const IndexBookmark = struct {
    prev_node_index: ?u32,
    text_index: u32,
};

pub const NodeType = @import("node.zig").NodeType;
pub const TextPartType = @import("text_part.zig").TextPartType;
pub const TextScannerType = @import("text_scanner.zig").TextScannerType;
pub const TrimmerType = @import("trimmer.zig").TrimmerType;
pub const FileReaderType = @import("file_reader.zig").FileReaderType;
pub const ParserType = @import("parser.zig").ParserType;

test {
    _ = testing.refAllDecls(@This());
}
