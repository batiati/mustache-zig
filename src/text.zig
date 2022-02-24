/// String and text manipulation helpers
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

pub fn fromString(content: []const u8) StringTextRope {
    return StringTextRope{ .content = content };
}

pub fn fromFile(allocator: Allocator, absolute_path: []const u8) anyerror!FileTextRope {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    return FileTextRope{
        .allocator = allocator,
        .file = file,
    };
}

pub const StringBuilder = struct {
    const Self = @This();

    const Chunk = struct {
        value: []const u8,
        next: ?*Chunk,
    };

    const Iterator = struct {
        current: ?*Chunk,

        pub fn init(builder: *const Self) Iterator {
            return .{ .current = builder.root };
        }

        pub fn next(self: *Iterator) ?*Chunk {
            if (self.current) |current| {
                self.current = current.next;
                return current;
            } else {
                return null;
            }
        }
    };

    root: ?*Chunk = null,
    current: ?*Chunk = null,

    pub fn init(arena: Allocator, value: []const u8) Allocator.Error!StringBuilder {
        var self = StringBuilder{};
        try self.append(arena, value);
        return self;
    }

    pub fn append(self: *Self, arena: Allocator, value: []const u8) Allocator.Error!void {
        var current = try arena.create(Chunk);
        errdefer arena.destroy(current);
        current.* = .{
            .next = null,
            .value = value,
        };

        if (self.current) |old| {
            old.next = current;
            self.current = current;
        } else {
            self.root = current;
            self.current = current;
        }
    }

    pub fn trimLeft(self: *Self, index: usize) void {
        var iter = Iterator.init(self);
        var pos: usize = 0;
        while (iter.next()) |chunk| {
            const slice_len = chunk.value.len;

            if (index >= pos) {
                if (index <= pos + slice_len) {
                    const relative_index = index - pos;
                    chunk.value = chunk.value[relative_index..];
                    return;
                } else {
                    chunk.value = chunk.value[0..0];
                }
            }

            pos += slice_len;
        }

        return;
    }

    pub fn trimRight(self: *Self, index: usize) void {
        var iter = Iterator.init(self);
        var pos: usize = 0;
        while (iter.next()) |chunk| {
            const slice_len = chunk.value.len;

            if (index < slice_len + pos) {
                if (index >= pos) {
                    const relative_index = index - pos;
                    chunk.value = chunk.value[0..relative_index];
                } else {
                    chunk.value = chunk.value[0..0];
                }
            }

            pos += slice_len;
        }

        return;
    }

    pub fn charAt(self: *const Self, index: usize) ?u8 {
        var iter = Iterator.init(self);
        var pos: usize = 0;
        while (iter.next()) |chunk| {
            const slice_len = chunk.value.len;

            if (index >= pos and index <= pos + slice_len) {
                const relative_index = index - pos;
                return chunk.value[relative_index];
            }

            pos += slice_len;
        }

        return null;
    }

    pub inline fn empty(self: *const Self) bool {
        return self.root == null;
    }

    pub inline fn firstChar(self: *const Self) u8 {
        var iter = Iterator.init(self);
        if (iter.next()) |first| {
            return first.value[0];
        } else {
            return '\x00';
        }
    }

    pub fn len(self: *Self) usize {
        var iter = Iterator.init(self);
        var tota_len: usize = 0;

        while (iter.next()) |chunk| {
            tota_len += chunk.value.len;
        }

        return tota_len;
    }

    pub fn toOwnedSlice(self: *Self, allocator: Allocator) Allocator.Error![]const u8 {
        const total_len = self.len();
        var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, total_len);

        var iter = Iterator.init(self);

        while (iter.next()) |chunk| {
            list.appendSliceAssumeCapacity(chunk.value);
        }

        return list.toOwnedSlice(allocator);
    }

    test "Single slice" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";
        var text = try Self.init(allocator, expected);
        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));

        text.trimRight(8);
        expected = expected[0..8];
        try testing.expectEqual(expected.len, text.len());
        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));

        text.trimLeft(3);
        expected = expected[3..];
        try testing.expectEqual(expected.len, text.len());
        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));
    }

    test "Multiple slices" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";
        var text = try Self.init(allocator, "01234");
        try text.append(allocator, "56789");
        try text.append(allocator, "ABCDE");

        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));

        text.trimRight(8);
        expected = expected[0..8];
        try testing.expectEqual(expected.len, text.len());
        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));

        text.trimLeft(3);
        expected = expected[3..];
        try testing.expectEqual(expected.len, text.len());
        try testing.expectEqualStrings(expected, try text.toOwnedSlice(allocator));
    }

    test "Trim Left" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        expected = expected[3..];
        builder.trimLeft(3);
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));
    }

    test "Trim Left all" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try builder.append(allocator, "ABCDE");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        expected = expected[12..];
        builder.trimLeft(12);
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));
    }

    test "Trim Left clear" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try builder.append(allocator, "ABCDE");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        // expected[15..] is Index out of range
        builder.trimLeft(15);
        try testing.expectEqual(@as(usize, 0), builder.len());
        try testing.expectEqualStrings("", try builder.toOwnedSlice(allocator));
    }

    test "Trim Right" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        expected = expected[0..7];
        builder.trimRight(7);
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));
    }

    test "Trim Right all" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try builder.append(allocator, "ABCDE");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        expected = expected[0..3];
        builder.trimRight(3);

        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));
    }

    test "Trim Right clear" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try builder.append(allocator, "56789");
        try builder.append(allocator, "ABCDE");
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));

        expected = expected[0..0];
        builder.trimRight(0);
        try testing.expectEqual(expected.len, builder.len());
        try testing.expectEqualStrings(expected, try builder.toOwnedSlice(allocator));
    }
};

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

test {
    testing.refAllDecls(@This());
}
