const std = @import("std");
const Allocator = std.mem.Allocator;

pub const template = @import("template.zig");



pub const Delimiters = @import("parser/scanner/scanner.zig").Delimiters;

pub const TemplateOptions = struct {
    delimiters: Delimiters = .{},
    error_on_missing_value: bool = false,
};

test {
    std.testing.refAllDecls(@This());
}
