const std = @import("std");

pub const TextScanner = @import("TextScanner.zig");
pub const TextPart = @import("TextPart.zig");
pub const Parser = @import("Parser.zig");

pub const tokens = struct {
    pub const Comments = '!';
    pub const Section = '#';
    pub const InvertedSection = '^';
    pub const CloseSection = '/';
    pub const Partials = '>';
    pub const Inheritance = '$';
    pub const NoEscape = '&';
    pub const Delimiters = '=';
};

pub const PartType = enum {
    StaticText,
    Comment,
    Delimiters,
    Interpolation,
    NoScapeInterpolation,
    Section,
    InvertedSection,
    CloseSection,
    Partials,
    Inheritance,

    pub fn canBeStandAlone(self: PartType) bool {
        return switch (self) {
            .StaticText,
            .Interpolation,
            .NoScapeInterpolation,
            => false,
            else => true,
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
    delimiter: []const u8,
};

pub const Event = union(enum) {
    Mark: Mark,
    Eof,
};

test {
    _ = Parser;
    _ = TextScanner;
    _ = TextPart;
}
