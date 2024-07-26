const std = @import("std");
const mustache = @import("mustache.zig");

const PocLambdas = struct {
    pub fn upper(text: *const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.writeFormat("a text not uppercase converted", .{});
    }
};

const Text = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn upper(self: *const Text, ctx: mustache.LambdaContext) !void {
        const content = try ctx.renderAlloc(self.allocator, ctx.inner_text);
        defer self.allocator.free(content);
        const upper_content = try std.ascii.allocUpperString(self.allocator, content);
        defer self.allocator.free(upper_content);
        try ctx.writeFormat("{s}", .{ upper_content, });
    }
};

test "poc" {
    const allocator = std.testing.allocator;

    const template = "{{#upper}}{{content}}{{/upper}}";

    const text = Text{ .allocator = allocator, .content = "An awesome text !", };
    const const_ptr_text = &text;

    const result = try mustache.allocRenderTextWithOptions(
        allocator,
        template,
        const_ptr_text,
        .{},
        //.{ .global_lambdas = PocLambdas, }
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings("AN AWESOME TEXT !", result);
}
