const std = @import("std");
const Allocator = std.mem.Allocator;

const template = @import("template.zig");
const rendering = @import("rendering/render.zig");

pub const ParseError = template.ParseError;
pub const LastError = template.LastError;

pub const TemplateOptions = template.TemplateOptions;
pub const Delimiters = template.Delimiters;
pub const Element = template.Element;
pub const Section = template.Section;
pub const Partial = template.Partial;
pub const Parent = template.Parent;
pub const Block = template.Block;
pub const CachedTemplate = template.CachedTemplate;

pub const loadCachedTemplate = template.loadCachedTemplate;
pub const loadCachedTemplateFromFile = template.loadCachedTemplateFromFile;

pub const renderCached = rendering.renderCached;
pub const renderAllocCached = rendering.renderAllocCached;
pub const renderFromString = rendering.renderFromString;
pub const renderAllocFromString = rendering.renderAllocFromString;

test {
    std.testing.refAllDecls(@This());
}
