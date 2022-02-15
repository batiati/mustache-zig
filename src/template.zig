const std = @import("std");
const Allocator = std.mem.Allocator;

pub usingnamespace @import("commons.zig");

pub fn Template(comptime HashType: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,

        pub fn init(allocator: Allocator, template_text: []const u8, options: TemplateOptions) !Self {}

        pub fn deinit(self: *Self) void {}

        pub fn render(self: *const Self, hash: HashType) ![]const u8 {}
    };
}
