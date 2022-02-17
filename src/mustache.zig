const std = @import("std");
const Allocator = std.mem.Allocator;

pub const template = @import("template.zig");
pub const Delimiters = @import("parser/scanner.zig").Delimiters;

test {
    std.testing.refAllDecls(@This());
}
