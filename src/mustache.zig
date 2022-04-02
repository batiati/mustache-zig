const std = @import("std");
const Allocator = std.mem.Allocator;

const template = @import("template.zig");
const rendering = @import("rendering/render.zig");

pub const ParseError = template.ParseError;
pub const ParseErrorDetail = template.ParseErrorDetail;
pub const ParseResult = template.ParseResult;

pub const options = @import("options.zig");

pub const Delimiters = template.Delimiters;
pub const Element = template.Element;
pub const Template = template.Template;

pub const parse = template.parse;
pub const parseFromFile = template.parseFromFile;

pub const render = rendering.render;
pub const allocRender = rendering.allocRender;
pub const allocRenderZ = rendering.allocRenderZ;
pub const bufRender = rendering.bufRender;
pub const bufRenderZ = rendering.bufRenderZ;
pub const renderText = rendering.renderText;
pub const allocRenderText = rendering.allocRenderText;
pub const allocRenderTextZ = rendering.allocRenderTextZ;
pub const renderFile = rendering.renderFile;
pub const allocRenderFile = rendering.allocRenderFile;
pub const allocRenderFileZ = rendering.allocRenderFileZ;

pub const LambdaContext = rendering.LambdaContext;

test {
    _ = template;
    _ = rendering;
}
