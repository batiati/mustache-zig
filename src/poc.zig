const std = @import("std");
const mustache = @import("mustache.zig");

const bad_text = "a text not uppercase converted";
const lower_text = "An awesome text !";
const upper_text = "AN AWESOME TEXT !";

const PocLambdas = struct {
    pub fn upper(text: *const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.writeFormat(bad_text, .{});
    }

    pub fn upper2(text: *const AllocatedText, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.writeFormat(bad_text, .{});
    }
};

const Text = struct {
    content: []const u8,
};

const AllocatedText = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn upper2(self: *const @This(), ctx: mustache.LambdaContext) !void {
        const content = try ctx.renderAlloc(self.allocator, ctx.inner_text);
        defer self.allocator.free(content);
        const upper_content = try std.ascii.allocUpperString(self.allocator, content);
        defer self.allocator.free(upper_content);
        try ctx.writeFormat("{s}", .{ upper_content, });
    }
};

fn ok (comptime str: [] const u8) !void
{
    const tty: std.io.tty.Config = .escape_codes;
    try tty.setColor(std.io.getStdErr().writer(), .green);
    std.debug.print("[POC global lambdas] " ++ str[5..] ++ ": OK", .{});
    try tty.setColor(std.io.getStdErr().writer(), .reset);
}

test "basic" {
    const allocator = std.testing.allocator;

    const template = "{{#upper}}{{content}}{{/upper}}";
    const text = Text{ .content = lower_text, };
    const const_ptr_text = &text;

    const result = try mustache.allocRenderTextWithOptions(
        allocator,
        template,
        const_ptr_text,
        .{ .global_lambdas = PocLambdas, }
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings(bad_text, result);
    try ok(@src().fn_name);
}

test "AllocatedText lambda override global lambda" {
    const allocator = std.testing.allocator;

    const template = "{{#upper2}}{{content}}{{/upper2}}";

    const text = AllocatedText{ .allocator = allocator, .content = lower_text, };
    const const_ptr_text = &text;

    const result = try mustache.allocRenderTextWithOptions(
        allocator,
        template,
        const_ptr_text,
        .{ .global_lambdas = PocLambdas, }
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings(upper_text, result);
    try ok(@src().fn_name);
}
