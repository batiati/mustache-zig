const mustache = @import("mustache.zig");
const Delimiters = mustache.Delimiters;

const builtin = @import("builtin");

/// General options for processing a mustache template
pub const TemplateOptions = struct {

    /// Template source options
    source: TemplateSource,

    /// Template output options
    output: ParserOutput,

    /// Those options affect both performance and supported Mustache features.
    /// Defaults to full-spec compatible.
    features: Features = .{},

    /// Template load mode
    /// Can be "runtime" or "comptime"
    load_mode: TemplateLoadMode = .runtime_loaded,

    pub fn isRefCounted(self: @This()) bool {
        return self.source == .Stream;
    }

    pub fn copyStrings(self: @This()) bool {
        return switch (self.output) {
            .Render => false,
            .Parse => switch (self.source) {
                .String => |option| option.copy_strings,
                .Stream => true,
            },
        };
    }
};

pub const TemplateLoadMode = union(enum) {
    runtime_loaded,
    comptime_loaded: struct {
        template_text: []const u8,
        default_delimiters: Delimiters,
    },
};

pub const TemplateSource = union(enum) {

    /// Loads a template from string
    String: struct {

        /// Use 'false' if the source string is static or lives enough
        copy_strings: bool = true,
    },

    /// Loads a template from a file or stream
    Stream: struct {

        /// Define the buffer size for reading the stream
        read_buffer_size: usize = 4 * 1024,
    },
};

pub const ParserOutput = enum {

    /// Parses a template
    /// Use this option for validation and to store a template for future rendering
    /// This option speeds up the rendering process when the same template is rendered many times
    Parse,

    /// Parses just enough to render directly, without storing the template.
    /// This option saves memory.
    Render,
};

pub const ParseTextOptions = struct {

    /// Use 'false' if the source string is static or lives enough
    copy_strings: bool,

    /// Those options affect both performance and supported Mustache features.
    /// Defaults to full-spec compatible.
    features: Features = .{},
};

pub const ParseFileOptions = struct {

    /// Define the buffer size for reading the stream
    read_buffer_size: usize = 4 * 1024,

    /// Those options affect both performance and supported Mustache features.
    /// Defaults to full-spec compatible.
    features: Features = .{},
};

pub const Features = struct {

    /// Allows redefining the delimiters through the tags '{{=' and '=}}'
    /// Disabling this option speeds up the parsing process.
    /// If disabled, any occurrence of '{{=' will result in a parse error
    allow_redefining_delimiters: bool = true,

    /// Preserve line breaks and indentations.
    /// This option is useful when rendering documents sensible to spaces such as `yaml` for example.
    /// Disabling this option speeds up the parsing process.
    /// Examples:
    /// [Line breaks](https://github.com/mustache/spec/blob/b2aeb3c283de931a7004b5f7a2cb394b89382369/specs/comments.yml#L38)
    /// [Indentation](https://github.com/mustache/spec/blob/b2aeb3c283de931a7004b5f7a2cb394b89382369/specs/partials.yml#L82)
    preseve_line_breaks_and_indentation: bool = true,

    /// Lambda expansion support
    lambdas: Lambdas = .{ .Enabled = .{} },
};

pub const Lambdas = union(enum) {

    /// Use this option if your data source does not implement lambda functions
    /// Disabling lambda support saves memory and speeds up the parsing process
    Disabled,

    /// Use this option to support lambda functions in your data sources
    Enabled: struct {

        /// Lambdas can expand to new tags, including another lambda
        /// Defines the max recursion depth to avoid infinite recursion when evaluating lambdas
        /// A recursive lambda will interpolate as an empty string, without erros
        max_recursion: u32 = 100,
    },
};

pub const ContextMisses = enum {
    Empty,
    Error,
};

pub const RenderTemplateOptions = struct {

    /// Defines the behavior when rendering a unknown context
    /// Mustache's spec says it must be rendered as an empty string
    /// However, in Debug mode it defaults to `Error` to avoid silently broken contexts.
    context_misses: ContextMisses = if (builtin.mode == .Debug) .Error else .Empty,
};

pub const RenderTextOptions = struct {

    /// Defines the behavior when rendering a unknown context
    /// Mustache's spec says it must be rendered as an empty string
    /// However, in Debug mode it defaults to `Error` to avoid silently broken contexts.
    context_misses: ContextMisses = if (builtin.mode == .Debug) .Error else .Empty,

    /// Those options affect both performance and supported Mustache features.
    /// Defaults to full-spec compatible.
    features: Features = .{},
};

pub const RenderFileOptions = struct {

    /// Defines the behavior when rendering a unknown context
    /// Mustache's spec says it must be rendered as an empty string
    /// However, in Debug mode it defaults to `Error` to avoid silently broken contexts.
    context_misses: ContextMisses = if (builtin.mode == .Debug) .Error else .Empty,

    /// Define the buffer size for reading the stream
    read_buffer_size: usize = 4 * 1024,

    /// Those options affect both performance and supported Mustache features.
    /// Defaults to full-spec compatible.
    features: Features = .{},
};

pub const RenderOptions = union(enum) {
    Template: RenderTemplateOptions,
    Text: RenderTextOptions,
    File: RenderFileOptions,
};
