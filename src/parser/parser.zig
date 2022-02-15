const std = @import("std");

pub const Processor = @import("processor.zig").Processor;

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
};

pub const Interpolation = struct {
    escaped: bool,
    key: []const u8,
};

pub const Section = struct {
    inverted: bool,
    key: []const u8,
    content: ?[]const Element,
};

pub const Partials = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Inheritance = struct {
    key: []const u8,
    content: ?[]const Element,
};

pub const Element = union(enum) {

    /// Static text
    StaticText: []const u8,

    /// Interpolation tags are used to integrate dynamic content into the template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the data to replace the tag.  A single period (`.`)
    /// indicates that the item currently sitting atop the context stack should be
    /// used; otherwise, name resolution is as follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object, the data is the value returned by the
    ///   method with the given name.
    ///   5) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// Data should be coerced into a string (and escaped, if appropriate) before
    /// interpolation.
    /// The Interpolation tags MUST NOT be treated as standalone.    
    Interpolation: Interpolation,

    /// Section tags and End Section tags are used in combination to wrap a section
    /// of the template for iteration
    /// These tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Section tag MUST be followed
    /// by an End Section tag with the same content within the same section.
    /// This tag's content names the data to replace the tag.  Name resolution is as
    /// follows:
    ///   1) Split the name on periods; the first part is the name to resolve, any
    ///   remaining parts should be retained.
    ///   2) Walk the context stack from top to bottom, finding the first context
    ///   that is a) a hash containing the name as a key OR b) an object responding
    ///   to a method with the given name.
    ///   3) If the context is a hash, the data is the value associated with the
    ///   name.
    ///   4) If the context is an object and the method with the given name has an
    ///   arity of 1, the method SHOULD be called with a String containing the
    ///   unprocessed contents of the sections; the data is the value returned.
    ///   5) Otherwise, the data is the value returned by calling the method with
    ///   the given name.
    ///   6) If any name parts were retained in step 1, each should be resolved
    ///   against a context stack containing only the result from the former
    ///   resolution.  If any part fails resolution, the result should be considered
    ///   falsey, and should interpolate as the empty string.
    /// If the data is not of a list type, it is coerced into a list as follows: if
    /// the data is truthy (e.g. `!!data == true`), use a single-element list
    /// containing the data, otherwise use an empty list.
    /// For each element in the data list, the element MUST be pushed onto the
    /// context stack, the section MUST be rendered, and the element MUST be popped
    /// off the context stack.
    /// Section and End Section tags SHOULD be treated as standalone when
    /// appropriate.    
    Section: Section,

    /// Partial tags are used to expand an external template into the current
    /// template.
    /// The tag's content MUST be a non-whitespace character sequence NOT containing
    /// the current closing delimiter.
    /// This tag's content names the partial to inject.  Set Delimiter tags MUST NOT
    /// affect the parsing of a partial.  The partial MUST be rendered against the
    /// context stack local to the tag.  If the named partial cannot be found, the
    /// empty string SHOULD be used instead, as in interpolations.
    /// Partial tags SHOULD be treated as standalone when appropriate.  If this tag
    /// is used standalone, any whitespace preceding the tag should treated as
    /// indentation, and prepended to each line of the partial before rendering.    
    Partials: Partials,

    /// Like partials, Parent tags are used to expand an external template into the
    /// current template. Unlike partials, Parent tags may contain optional
    /// arguments delimited by Block tags. For this reason, Parent tags may also be
    /// referred to as Parametric Partials.
    /// The Parent tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter; each Parent tag MUST be followed by
    /// an End Section tag with the same content within the matching Parent tag.
    /// This tag's content names the Parent template to inject. Set Delimiter tags
    /// Preceding a Parent tag MUST NOT affect the parsing of the injected external
    /// template. The Parent MUST be rendered against the context stack local to the
    /// tag. If the named Parent cannot be found, the empty string SHOULD be used
    /// instead, as in interpolations.
    /// Parent tags SHOULD be treated as standalone when appropriate. If this tag is
    /// used standalone, any whitespace preceding the tag should be treated as
    /// indentation, and prepended to each line of the Parent before rendering.
    /// The Block tags' content MUST be a non-whitespace character sequence NOT
    /// containing the current closing delimiter. Each Block tag MUST be followed by
    /// an End Section tag with the same content within the matching Block tag. This
    /// tag's content determines the parameter or argument name.
    /// Block tags may appear both inside and outside of Parent tags. In both cases,
    /// they specify a position within the template that can be overridden; it is a
    /// parameter of the containing template. The template text between the Block tag
    /// and its matching End Section tag defines the default content to render when
    /// the parameter is not overridden from outside.
    /// In addition, when used inside of a Parent tag, the template text between a
    /// Block tag and its matching End Section tag defines content that replaces the
    /// default defined in the Parent template. This content is the argument passed
    /// to the Parent template.try self.parseAction(.Partial, content)
    /// The practice of injecting an external template using a Parent tag is referred
    /// to as inheritance. If the Parent tag includes a Block tag that overrides a
    /// parameter of the Parent template, this may also be referred to as
    /// substitution.
    /// Parent templates are taken from the same namespace as regular Partial
    /// templates and in fact, injecting a regular Partial is exactly equivalent to
    /// injecting a Parent without making any substitutions. Parameter and arguments
    /// names live in a namespace that is distinct from both Partials and the context.
    Inheritance: Inheritance,
};

test {
    std.testing.refAllDecls(@This());
}
