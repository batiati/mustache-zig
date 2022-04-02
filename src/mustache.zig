const std = @import("std");
const Allocator = std.mem.Allocator;

const template = @import("template.zig");
const rendering = @import("rendering/render.zig");

pub const ParseError = template.ParseError;
pub const LastError = template.LastError;

pub const Options = template.Options;
pub const Delimiters = template.Delimiters;
pub const Element = template.Element;
pub const Section = template.Section;
pub const Partial = template.Partial;
pub const Parent = template.Parent;
pub const Block = template.Block;
pub const Template = template.Template;

pub const parseTemplate = template.parseTemplate;
pub const parseTemplateFromFile = template.parseTemplateFromFile;

pub const render = rendering.render;
pub const allocRender = rendering.allocRender;
pub const allocRenderZ = rendering.allocRenderZ;
pub const bufRender = rendering.bufRender;
pub const bufRenderZ = rendering.bufRenderZ;

pub const renderFromString = rendering.renderFromString;
pub const renderFromFile = rendering.renderFromFile;
pub const renderAllocFromString = rendering.renderAllocFromString;

pub const LambdaContext = rendering.LambdaContext;

test {
    _ = template;
    _ = rendering;
}
