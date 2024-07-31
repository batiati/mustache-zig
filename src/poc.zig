const std = @import("std");
const mustache = @import("mustache.zig");

const bad_text = "a text not uppercase converted";
const lower_text = "An awesome text !";
const upper_text = "AN AWESOME TEXT !";

const PocLambdas = struct {
    pub fn upper1arg(ctx: mustache.LambdaContext) !void {
        var content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
        defer ctx.allocator.?.free(content);
        for (content, 0..) |char, i| {
            content[i] = std.ascii.toUpper(char);
        }
        try ctx.write(content);
    }

    pub fn upper(text: *Dummy, ctx: mustache.LambdaContext) !void {
        text.content = try std.ascii.allocUpperString(ctx.allocator.?, text.content);
        defer ctx.allocator.?.free(text.content);
        try ctx.write(text.content);
    }

    pub fn lower_and_upper(text: *Dummy, ctx: mustache.LambdaContext) !void {
        _ = text;
        const content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
        defer ctx.allocator.?.free(content);
        //for (content, 0..) |char, i| {
        //    content[i] = std.ascii.toUpper(char);
        //}
        //try ctx.write(text.content);
        //try ctx.write(" ");
        try ctx.write(content);
    }

    // Conflicting methods
    pub fn upperSectionConflict(text: *const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.write(bad_text);
    }

    pub fn upperInterpolationConflict(text: *const Text, ctx: mustache.LambdaContext) !void {
        _ = text;
        try ctx.write(bad_text);
    }
};

// struct without methods: no conflicts with global lambdas
const Dummy = struct {
    content: []const u8,
};

// struct with conflicting methods
const Text = struct {
    content: []const u8,

    pub fn upperInterpolationConflict(self: *const @This(), ctx: mustache.LambdaContext) !void {
        const upper_content = try std.ascii.allocUpperString(ctx.allocator.?, self.content);
        defer ctx.allocator.?.free(upper_content);
        try ctx.write(upper_content);
    }

    pub fn upperSectionConflict(_: *const @This(), ctx: mustache.LambdaContext) !void {
        const content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
        defer ctx.allocator.?.free(content);
        const upper_content = try std.ascii.allocUpperString(ctx.allocator.?, content);
        defer ctx.allocator.?.free(upper_content);
        try ctx.write(upper_content);
    }
};

// a bit of color to enlight my tests
fn ok(comptime str: []const u8) !void {
    const tty: std.io.tty.Config = .escape_codes;
    try tty.setColor(std.io.getStdErr().writer(), .green);
    std.debug.print("[POC global lambdas] " ++ str[5..] ++ ": OK\n", .{});
    try tty.setColor(std.io.getStdErr().writer(), .reset);
}

test "section: only LambdaContext" {
    const allocator = std.testing.allocator;

    const template = "{{#upper1arg}}" ++ lower_text ++ "{{/upper1arg}}";
    const text = Dummy{
        .content = lower_text,
    };
    const ptr_text = &text;

    const result = try mustache.allocRenderTextWithOptions(allocator, template, ptr_text, .{
        .global_lambdas = PocLambdas,
    });
    defer allocator.free(result);

    try std.testing.expectEqualStrings(upper_text, result);
    try ok(@src().fn_name);
}

test "interpolation: struct + LambdaContext" {
    const allocator = std.testing.allocator;

    const template = "{{upper}}";
    var text = Dummy{ .content = lower_text, };
    const ptr_text = &text;

    const result = try mustache.allocRenderTextWithOptions(
        allocator,
        template,
        ptr_text,
        .{ .global_lambdas = PocLambdas, },
    );
    defer allocator.free(result);

    try std.testing.expectEqualStrings(upper_text, result);
    try ok(@src().fn_name);
}

//test "section: struct + LambdaContext" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{#lower_and_upper}}{{content}}{{/lower_and_upper}}";
//    var text = Dummy{ .content = lower_text, };
//    const ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        ptr_text,
//        .{ .global_lambdas = PocLambdas, },
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(lower_text ++ " " ++ upper_text, result);
//    try ok(@src().fn_name);
//}

//test "interpolation: conflict between Text lambda and global lambda" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{upperInterpolationConflict}}";
//
//    const text = Text{ .allocator = allocator, .content = lower_text, };
//    const ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        ptr_text,
//        .{ .global_lambdas = PocLambdas, }
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(upper_text, result);
//    try ok(@src().fn_name);
//}

//test "section: conflict between Text lambda and global lambda" {
//    const allocator = std.testing.allocator;
//
//    const template = "{{#upperSectionConflict}}{{content}}{{/upperSectionConflict}}";
//
//    const text = Text{ .allocator = allocator, .content = lower_text, };
//    const ptr_text = &text;
//
//    const result = try mustache.allocRenderTextWithOptions(
//        allocator,
//        template,
//        ptr_text,
//        .{ .global_lambdas = PocLambdas, }
//    );
//    defer allocator.free(result);
//
//    try std.testing.expectEqualStrings(upper_text, result);
//    try ok(@src().fn_name);
//}
