const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn fromString(content: []const u8) StringTextRope {
    return StringTextRope{ .content = content };
}

pub fn fromFile(allocator: Allocator, absolute_path: []const u8) anyerror!FileTextRope {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    return .{
        .allocator = allocator,
        .file = file,
    };
}

pub const StringTextRope = struct {
    const Self = @This();

    content: ?[]const u8,

    pub fn next(self: *Self) anyerror!?[]const u8 {
        if (self.content) |content| {
            self.content = null;
            return content;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }
};

pub const FileTextRope = struct {
    const BUFFER_SIZE = 4096;
    const Self = @This();

    allocator: Allocator,
    file: std.fs.File,

    fn next(self: *Self) anyerror!?[]const u8 {
        var buffer = try self.allocator.alloc(u8, BUFFER_SIZE);
        errdefer self.allocator.free(buffer);

        var size = try self.file.read(buffer);
        if (size == 0) {
            self.allocator.free(buffer);
            return null;
        } else if (size < buffer.len) {
            self.allocator.free(buffer[size..]);
            return buffer[0..size];
        } else {
            return buffer;
        }
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
    }
};
