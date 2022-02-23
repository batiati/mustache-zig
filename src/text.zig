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

    const Content = enum {
        Empty,
        Single,
        Multiple,
    };

    const Iterator = struct {

        content: union(Content) {
            Empty,
            Single: *[]const u8,
            Multiple: *Chunk,
        },        

        pub fn init(builder: *Self) Iterator {
            
            return switch (builder.content) {
                .Empty => .{ .content = .Empty },
                .Single => |*value| .{ .content = .{ .Single = value } },
                .Multiple => |content| .{ .content = .{ .Multiple = content.root } },
            };
        }

        pub fn next(self: *Iterator) ?*[]const u8 {

            return switch (self.content) {
                .Empty => null,
                .Single => |value| blk: {
                    self.content = .Empty; 
                    break :blk value;
                },
                .Multiple => |*chunk| blk: {
                    const current = &chunk.*.value;
                    
                    if (chunk.*.next) |next_chunk| {
                        chunk.* = next_chunk;
                    } else {
                        self.content = .Empty; 
                    }
                    
                    break :blk current;
                },
            };
        }
    };

    content: union(Content) {
        Empty,
        Single: []const u8,
        Multiple: struct {
            root: *Chunk,
            current: *Chunk,
        }
    } = .Empty,

    pub fn init(value: []const u8) StringBuilder {
    
        return StringBuilder{
            .content = .{ .Single = value },
        };
    }

    fn iterator(self: *Self) Iterator {
        return Iterator.init(self);
    }

    pub fn append(self: *Self, allocator: Allocator, value: []const u8) Allocator.Error!void {
        
        switch (self.content) {

            .Empty => {
                self.content = .{ .Single = value };
            },
            .Single => |current_value| {

                var current = try allocator.create(Chunk);
                errdefer allocator.destroy(current);
                current.* = .{
                    .next = null,
                    .value = value,
                };

                var root = try allocator.create(Chunk);
                errdefer allocator.destroy(root);
                root.* = .{
                    .next = current,
                    .value = current_value,
                };

                self.content = .{
                    .Multiple = .{
                        .root = root,
                        .current = current,
                    },
                };
            },
            .Multiple => |*content| {

                var current = try allocator.create(Chunk);
                errdefer allocator.destroy(current);
                current.* = .{
                    .next = null,
                    .value = value,
                };

                content.current.next = current;
                content.current = current;
            },
        }
    }

    pub fn trimLeft(self: *Self, index: usize) void {
        var iter = self.iterator();
        var pos: usize = 0;
        while (iter.next()) |slice| {
            const slice_len = slice.len;

            if (index >= pos) {
                if (index <= pos + slice_len) {
                    const relative_index = index - pos;
                    slice.* = slice.*[relative_index..];
                    return;
                } else {
                    slice.* = slice.*[0..0];
                }
            }

            pos += slice_len;
        }

        return;
    }

    pub fn trimRight(self: *Self, index: usize) void {
        var iter = self.iterator();
        var pos: usize = 0;
        while (iter.next()) |slice| {
            const slice_len = slice.len;

            if (index < slice.len + pos) {
                if (index >= pos) {
                    const relative_index = index - pos;
                    slice.* = slice.*[0..relative_index];
                } else {
                    slice.* = slice.*[0..0];
                }
            }

            pos += slice_len;
        }

        return;
    }

    pub fn charAt(self: *const Self, index: usize) ?u8 {
        var iter = self.iterator();
        var pos: usize = 0;
        while (iter.next()) |slice| {
            const slice_len = slice.len;

            if (index >= pos and index <= pos + slice_len) {
                const relative_index = index - pos;
                return slice[relative_index];
            }

            pos += slice_len;
        }

        return null;
    }

    pub inline fn empty(self: *const Self) bool {
        return self.content == .Empty;
    }

    pub inline fn firstChar(self: *const Self) u8 {
        var iter = self.iterator();
        if (iter.next()) |first| {
            return first[0];
        } else {
            return '\x00';
        }
    }

    pub fn len(self: *Self) usize {
        var iter = self.iterator();
        var tota_len: usize = 0;

        while (iter.next()) |item| {
            tota_len += item.len;
        }

        return tota_len;
    }

    pub fn toOwnedSlice(self: *Self, allocator: Allocator) Allocator.Error![]const u8 {
        const total_len = self.len();
        var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, total_len);

        var iter = self.iterator();

        while (iter.next()) |slice| {
            list.appendSliceAssumeCapacity(slice.*);
        }

        return list.toOwnedSlice(allocator);
    }

    test "Single slice" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var expected: []const u8 = "0123456789ABCDE";
        var text = Self.init(expected);
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
        var text = Self.init("01234");
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
