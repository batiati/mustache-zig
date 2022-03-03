const std = @import("std");
const Allocator = std.mem.Allocator;

pub const template = @import("template.zig");

test {
    _ = @import("context.zig");
    _ = @import("render.zig");
    std.testing.refAllDecls(@This());
}
