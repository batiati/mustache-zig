const std = @import("std");
const mustache = @import("mustache.zig");

const PocLambdas = struct {
    pub fn upper(ctx: mustache.LambdaContext) !void {
        try ctx.writeFormat("a text not uppercase converted", .{});
    }
};

const Text = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn upper(self: *Text, ctx: mustache.LambdaContext) !void {
        const content = try ctx.renderAlloc(self.allocator, ctx.inner_text);
        defer self.allocator.free(content);
        std.debug.print ("content: {s}\n", .{content,});
        const upper_content = try std.ascii.allocUpperString(self.allocator, content);
        defer self.allocator.free(upper_content);
        std.debug.print ("upper_content: {s}\n", .{upper_content,});
        try ctx.writeFormat("PATATA{s}", .{ upper_content, });
    }
};

test "poc" {
    const allocator = std.testing.allocator;

    const template = "{{#upper}}{{content}}{{/upper}}";

    const text = Text{ .allocator = allocator, .content = "An awesome text !", };
    const result = try mustache.allocRenderTextWithOptions(
        allocator,
        template,
        text,
        .{},
        //.{ .global_lambdas = PocLambdas, }
    );
    defer allocator.free(result);

    //try std.testing.expectEqualStrings("AN AWESOME TEXT !" , result);
}
