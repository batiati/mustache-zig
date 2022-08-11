/// This interface is invoked by the FFI export function implementation
/// mustache_interpolate
const std = @import("std");

const context = @import("../rendering/context.zig");
const Escape = context.Escape;

const Self = @This();

handle: *anyopaque,
escape: Escape,
writeFn: fn (*anyopaque, []const u8, Escape) anyerror!void,

pub inline fn write(self: Self, value: []const u8) anyerror!void {
    try self.writeFn(self.handle, value, self.escape);
}
