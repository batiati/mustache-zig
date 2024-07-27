const std = @import("std");
const mustache = @import("mustache.zig");

const bad_text = "a text not uppercase converted";
const lower_text = "An awesome text !";
const upper_text = "AN AWESOME TEXT !";

const PocLambdas = struct {
    pub fn upperSection(const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.write(bad_text);
    }

    pub fn upperSection2(text: *const AllocatedText, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.write(bad_text);
    }

    pub fn upperInterpolation(text: *const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.write(bad_text);
    }

    //pub const upperInterpolation = upperSection;
    pub const upperInterpolation2 = upperSection2;
};

const Text = struct {
    content: []const u8,
    //pub fn upperInterpolation(_: *const @This(), ctx: mustache.LambdaContext) !void {
    //    try ctx.write(upper_text);
    //}
};

const AllocatedText = struct {
    allocator: std.mem.Allocator,
    content: []const u8,

    pub fn upperInterpolation2(self: *const @This(), ctx: mustache.LambdaContext) !void {
        const upper_content = try std.ascii.allocUpperString(self.allocator, self.content);
        defer self.allocator.free(upper_content);
        try ctx.writeFormat("{s}", .{ upper_content, });
    }

    pub fn upperSection2(self: *const @This(), ctx: mustache.LambdaContext) !void {
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
    std.debug.print("[POC global lambdas] " ++ str[5..] ++ ": OK\n", .{});
    try tty.setColor(std.io.getStdErr().writer(), .reset);
}

//test "section: basic" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{#upperSection}}{{content}}{{/upperSection}}";
//    const text = Text{ .content = lower_text, };
//    const const_ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        const_ptr_text,
//        .{ .global_lambdas = PocLambdas, }
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(bad_text, result);
//    try ok(@src().fn_name);
//}

test "interpolation: basic" {
    const allocator = std.testing.allocator;

    const template = "{{upperInterpolation}}";
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

//test "section: AllocatedText lambda override global lambda" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{#upperSection2}}{{content}}{{/upperSection2}}";
//
//    const text = AllocatedText{ .allocator = allocator, .content = lower_text, };
//    const const_ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        const_ptr_text,
//        .{ .global_lambdas = PocLambdas, }
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(upper_text, result);
//    try ok(@src().fn_name);
//}

//test "interpolation: AllocatedText lambda override global lambda" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{upperInterpolation2}}";
//
//    const text = AllocatedText{ .allocator = allocator, .content = lower_text, };
//    const const_ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        const_ptr_text,
//        .{ .global_lambdas = PocLambdas, }
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(upper_text, result);
//    try ok(@src().fn_name);
//}
