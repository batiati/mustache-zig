const std = @import("std");

const mustache = @import("../mustache.zig");
const Options = mustache.Options;

const assert = std.debug.assert;
const testing = std.testing;

pub const Delimiters = struct {
    pub const DefaultStartingDelimiter = "{{";
    pub const DefaultEndingDelimiter = "}}";

    starting_delimiter: []const u8 = DefaultStartingDelimiter,
    ending_delimiter: []const u8 = DefaultEndingDelimiter,
};

pub const tokens = struct {
    pub const Comments = '!';
    pub const Section = '#';
    pub const InvertedSection = '^';
    pub const CloseSection = '/';
    pub const Partial = '>';
    pub const Parent = '<';
    pub const Block = '$';
    pub const NoEscape = '&';
    pub const Delimiters = '=';
};

pub const BlockType = enum {
    StaticText,
    Comment,
    Delimiters,
    Interpolation,
    UnescapedInterpolation,
    Section,
    InvertedSection,
    CloseSection,
    Partial,
    Parent,
    Block,

    pub fn canBeStandAlone(self: BlockType) bool {
        return switch (self) {
            .StaticText,
            .Interpolation,
            .UnescapedInterpolation,
            => false,
            else => true,
        };
    }

    pub fn ignoreStaticText(self: BlockType) bool {
        return switch (self) {
            .Parent => true,
            else => false,
        };
    }
};

pub const MarkType = enum {

    /// A starting tag mark, such '{{', '{{{' or any configured delimiter
    Starting,

    /// A ending tag mark, such '}}', '}}}' or any configured delimiter
    Ending,
};

pub const DelimiterType = enum {

    /// Delimiter is '{{', '}}', or any configured delimiter
    Regular,

    /// Delimiter is a non-scaped (aka triple mustache) delimiter such '{{{' or '}}}' 
    NoScapeDelimiter,
};

pub const Mark = struct {
    mark_type: MarkType,
    delimiter_type: DelimiterType,
    delimiter_len: u32,
};

pub const Event = union(enum) {
    Mark: Mark,
    Eof,
};

pub fn TrimmingIndex(comptime options: Options) type {
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

pub const Level = @import("level.zig").Level;
pub const Node = @import("node.zig").Node;
pub const TextBlock = @import("text_block.zig").TextBlock;
pub const TextScanner = @import("text_scanner.zig").TextScanner;
pub const Trimmer = @import("trimmer.zig").Trimmer;
pub const FileReader = @import("file_reader.zig").FileReader;
pub const Parser = @import("parser.zig").Parser;

test {
    _ = testing.refAllDecls(@This());
}
