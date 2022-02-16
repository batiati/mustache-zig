const std = @import("std");
const Allocator = std.mem.Allocator;

pub usingnamespace @import("commons.zig");
pub const template = @import("template.zig");

//pub const Template = @import("template.zig").Template;
//pub const ComptimeTemplate = @import("comptime_template.zig").ComptimeTemplate;

// Renders from a runtime known mustache template.
// Caller owns the returned slice
//pub fn render(allocator: Allocator, template_text: []const u8, hash: anytype) RenderError![]const u8 {
//    var template = try Template(@TypeOf(hash)).init(allocator, template_text, .{});
//    defer template.deinit();
//
//    return try template.render(hash);
//}

//
// Renders from a comptime known mustache template.
// Caller owns the returned slice
//pub fn comptime_render(allocator: Allocator, comptime template_text: []const u8, hash: anytype) RenderError![]const u8 {
//    var template = try ComptimeTemplate(@TypeOf(hash), template_text, .{}).init(allocator);
//    defer template.deinit();
//
//    return try template.render(hash);
//}

test {
    _ = template;
}
