const std = @import("std");
const Allocator = std.mem.Allocator;

pub const template = @import("template.zig");

test {
    std.testing.refAllDecls(@This());
}
