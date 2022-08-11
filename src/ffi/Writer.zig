/// This interface is invoked by the FFI export function implementation "mustache_interpolate"
/// Note this interface must be implemented using the @fieldParentPtr approach
/// This is an advantage for passing just one pointer as the "writer_handler"
const std = @import("std");

const context = @import("../rendering/context.zig");
const Escape = context.Escape;

const Self = @This();

writeFn: fn (*Self, []const u8) anyerror!void,

pub inline fn write(self: *Self, value: []const u8) anyerror!void {
    try self.writeFn(self, value);
}
