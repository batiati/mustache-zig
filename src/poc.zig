const std = @import("std");
const mustache = @import("mustache.zig");

const allocator = std.testing.allocator;

const bad_text = "a text not uppercase converted";
const lower_text = "An awesome text !";
const upper_text = "AN AWESOME TEXT !";

// a bit of color to enlight my tests
fn headerlessOk(comptime header: []const u8, comptime str: []const u8) !void {
    const tty: std.io.tty.Config = .escape_codes;
    try tty.setColor(std.io.getStdErr().writer(), .green);
    std.debug.print("[" ++ header ++ " global lambdas] " ++ str[5..] ++ ": OK\n", .{});
    try tty.setColor(std.io.getStdErr().writer(), .reset);
}

const Native = struct {
    fn ok(comptime str: []const u8) !void {
        try headerlessOk("Native", str);
    }

    const GlobalLambdas = struct {
        pub fn upper1arg(ctx: mustache.LambdaContext) !void {
            var content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
            defer ctx.allocator.?.free(content);
            for (content, 0..) |char, i| {
                content[i] = std.ascii.toUpper(char);
            }
            try ctx.write(content);
        }

        pub fn upper(text: *Text, ctx: mustache.LambdaContext) !void {
            text.content = try std.ascii.allocUpperString(ctx.allocator.?, text.content);
            defer ctx.allocator.?.free(text.content);
            try ctx.write(text.content);
        }

        pub fn lower_and_upper(text: *Text, ctx: mustache.LambdaContext) !void {
            try ctx.write(text.content);
            const content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
            defer ctx.allocator.?.free(content);
            for (content, 0..) |char, i| {
                content[i] = std.ascii.toUpper(char);
            }
            try ctx.write(" ");
            try ctx.write(content);
        }

        // Conflicting methods
        pub fn upperInterpolationConflict(text: *const ConflictingText, ctx: mustache.LambdaContext) !void {
            _ = text;
            try ctx.write(bad_text);
        }

        pub fn upperSectionConflict(text: *const ConflictingText, ctx: mustache.LambdaContext) !void {
            _ = text;
            try ctx.write(bad_text);
        }
    };

    // struct without methods: no conflicts with global lambdas
    const Text = struct {
        content: []const u8,
    };

    // struct with conflicting methods
    const ConflictingText = struct {
        content: []const u8,

        pub fn upperInterpolationConflict(self: *const @This(), ctx: mustache.LambdaContext) !void {
            const upper_content = try std.ascii.allocUpperString(ctx.allocator.?, self.content);
            defer ctx.allocator.?.free(upper_content);
            try ctx.write(upper_content);
        }

        pub fn upperSectionConflict(self: *const @This(), ctx: mustache.LambdaContext) !void {
            try ctx.write(self.content);
            const content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
            defer ctx.allocator.?.free(content);
            for (content, 0..) |char, i| {
                content[i] = std.ascii.toUpper(char);
            }
            try ctx.write(" ");
            try ctx.write(content);
        }
    };

    test "section: only LambdaContext" {
        const template = "{{#upper1arg}}" ++ lower_text ++ "{{/upper1arg}}";
        const text = Text{ .content = lower_text };
        const ptr_text = &text;

        const result = try mustache.allocRenderTextWithOptions(allocator, template, ptr_text, .{ .global_lambdas = GlobalLambdas });
        defer allocator.free(result);

        try std.testing.expectEqualStrings(upper_text, result);
        try ok(@src().fn_name);
    }

    test "interpolation: struct + LambdaContext" {
        const template = "{{upper}}";
        var text = Text{ .content = lower_text };
        const ptr_text = &text;

        const result = try mustache.allocRenderTextWithOptions(
            allocator,
            template,
            ptr_text,
            .{ .global_lambdas = GlobalLambdas },
        );
        defer allocator.free(result);

        try std.testing.expectEqualStrings(upper_text, result);
        try ok(@src().fn_name);
    }

    test "section: struct + LambdaContext" {
        const template = "{{#lower_and_upper}}{{content}}{{/lower_and_upper}}";
        var text = Text{ .content = lower_text };
        const ptr_text = &text;

        const result = try mustache.allocRenderTextWithOptions(
            allocator,
            template,
            ptr_text,
            .{ .global_lambdas = GlobalLambdas },
        );
        defer allocator.free(result);

        try std.testing.expectEqualStrings(lower_text ++ " " ++ upper_text, result);
        try ok(@src().fn_name);
    }

    test "interpolation: conflict between ConflictingText lambda and global lambda" {
        const template = "{{upperInterpolationConflict}}";

        const text = ConflictingText{ .content = lower_text };
        const ptr_text = &text;

        const result = try mustache.allocRenderTextWithOptions(allocator, template, ptr_text, .{ .global_lambdas = GlobalLambdas });
        defer allocator.free(result);

        try std.testing.expectEqualStrings(upper_text, result);
        try ok(@src().fn_name);
    }

    test "section: conflict between ConflictingText lambda and global lambda" {
        const template = "{{#upperSectionConflict}}{{content}}{{/upperSectionConflict}}";

        const text = ConflictingText{ .content = lower_text };
        const ptr_text = &text;

        const result = try mustache.allocRenderTextWithOptions(allocator, template, ptr_text, .{ .global_lambdas = GlobalLambdas });
        defer allocator.free(result);

        try std.testing.expectEqualStrings(lower_text ++ " " ++ upper_text, result);
        try ok(@src().fn_name);
    }
};

const Json = struct {
    fn ok(comptime str: []const u8) !void {
        try headerlessOk("JSON", str);
    }

    const GlobalLambdas = struct {
        pub fn upper1arg(ctx: mustache.LambdaContext) !void {
            var content = try ctx.renderAlloc(ctx.allocator.?, ctx.inner_text);
            defer ctx.allocator.?.free(content);
            for (content, 0..) |char, i| {
                content[i] = std.ascii.toUpper(char);
            }
            try ctx.write(content);
        }
    };

    test "section: only LambdaContext" {
        const template = "{{#upper1arg}}" ++ lower_text ++ "{{/upper1arg}}";

        const value = std.json.Value{ .string = "A text in a std.json.Value.string" };

        const result = try mustache.allocRenderTextWithOptions(allocator, template, value, .{ .global_lambdas = GlobalLambdas });
        defer allocator.free(result);

        try std.testing.expectEqualStrings(upper_text, result);
        try ok(@src().fn_name);
    }
};

test {
    _ = Native;
    _ = Json;
}
