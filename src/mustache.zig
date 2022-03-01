const std = @import("std");
const Allocator = std.mem.Allocator;

pub const template = @import("template.zig");

test {
    _ = @import("data_binder.zig");
    std.testing.refAllDecls(@This());
}
