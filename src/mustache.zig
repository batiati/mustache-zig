const std = @import("std");
const Allocator = std.mem.Allocator;

const template = @import("template.zig");
const rendering = @import("rendering/rendering.zig");

pub const ParseError = template.ParseError;
pub const ParseErrorDetail = template.ParseErrorDetail;
pub const ParseResult = template.ParseResult;

pub const options = @import("options.zig");

pub const Delimiters = template.Delimiters;
pub const Element = template.Element;
pub const Template = template.Template;

pub const parseText = template.parseText;
pub const parseFile = template.parseFile;

pub const render = rendering.render;
pub const renderPartials = rendering.renderPartials;
pub const renderPartialsWithOptions = rendering.renderPartialsWithOptions;
pub const allocRender = rendering.allocRender;
pub const allocRenderPartials = rendering.allocRenderPartials;
pub const allocRenderPartialsWithOptions = rendering.allocRenderPartialsWithOptions;
pub const allocRenderZ = rendering.allocRenderZ;
pub const allocRenderPartialsZ = rendering.allocRenderPartialsZ;
pub const allocRenderPartialsZWithOptions = rendering.allocRenderPartialsZWithOptions;
pub const bufRender = rendering.bufRender;
pub const bufRenderPartials = rendering.bufRenderPartials;
pub const bufRenderPartialsWithOptions = rendering.bufRenderPartialsWithOptions;
pub const bufRenderZ = rendering.bufRenderZ;
pub const bufRenderPartialsZ = rendering.bufRenderPartialsZ;
pub const bufRenderPartialsZWithOptions = rendering.bufRenderPartialsZWithOptions;
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
