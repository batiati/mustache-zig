const std = @import("std");
const Allocator = std.mem.Allocator;

pub usingnamespace @import("commons.zig");

pub fn ComptimeTemplate(comptime HashType: type, comptime template_text: []const u8, comptime options: TemplateOptions) type {
    return struct {
        const Self = @This();

        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {}

        pub fn deinit(self: *Self) void {}

        pub fn render(self: *const Self, hash: HashType) ![]const u8 {}
    };
}
