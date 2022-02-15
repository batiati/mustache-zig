const std = @import("std");

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

pub const TagType = enum {
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

    pub fn canBeStandAlone(self: TagType) bool {
        return switch (self) {
            .StaticText,
            .Interpolation,
            .NoScapeInterpolation,
            => false,
            else => true,
        };
    }
};

pub const DelimiterType = enum {

    /// Delimiter is '{{', '}}', or any configured delimiter
    Regular,

    /// Delimiter is a non-scaped (aka triple mustache) delimiter such '{{{' or '}}}' 
    NoScapeDelimiter,
};

pub const TagMarkType = enum {

    /// A starting tag mark, such '{{', '{{{' or any configured delimiter
    Starting,

    /// A ending tag mark, such '}}', '}}}' or any configured delimiter
    Ending,
};

pub const TagMark = struct {
    tag_mark_type: TagMarkType,
    delimiter_type: DelimiterType,
    delimiter: []const u8,
};

pub const TextPart = struct {
    pub const Event = union(enum) {
        TagMark: TagMark,
        Eof,
    };

    const Self = @This();

    event: Event,
    tail: ?[]const u8,
    row: usize,
    col: usize,

    pub fn readTagType(self: *Self) ?TagType {
        if (self.tail) |tail| {
            const match = switch (tail[0]) {
                tokens.Comments => TagType.Comment,
                tokens.Section => TagType.Section,
                tokens.InvertedSection => TagType.InvertedSection,
                tokens.Partials => TagType.Partials,
                tokens.Inheritance => TagType.Inheritance,
                tokens.Delimiters => TagType.Delimiters,
                tokens.NoEscape => TagType.NoScapeInterpolation,
                tokens.CloseSection => TagType.CloseSection,
                else => null,
            };

            if (match) |tag_type| {
                self.tail = tail[1..];
                return tag_type;
            }
        }

        return null;
    }

    pub fn trimStandAloneTag(self: *Self, trim: enum { Left, Right }) void {
        if (self.tail) |tail| {
            if (tail.len > 0) {
                switch (trim) {
                    .Left => {
                        var index: usize = 0;
                        while (index < tail.len) : (index += 1) {
                            switch (tail[index]) {
                                ' ', '\t' => {},
                                '\r', '\n' => {
                                    self.tail = tail[index + 1 ..];
                                    return;
                                },
                                else => return,
                            }
                        }

                        self.tail = null;
                    },

                    .Right => {
                        var index: usize = 0;
                        while (index < tail.len) : (index += 1) {
                            const end = tail.len - index - 1;
                            switch (tail[end]) {
                                ' ', '\t' => {},
                                '\r', '\n' => {
                                    self.tail = tail[0 .. end + 1];
                                    return;
                                },
                                else => return,
                            }
                        }
                    },
                }
            }

            self.tail = null;
        }
    }
};
