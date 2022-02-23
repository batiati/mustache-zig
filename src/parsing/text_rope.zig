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

pub const TextSlice = union(enum) {
    const Self = @This();

    Single: []const u8,
    Multiple: [][]const u8,

    pub fn init(value: []const u8) TextSlice {
        return .{
            .Single = value,
        };
    }

    pub fn append(self: *Self, allocator: Allocator, value: []const u8) !void {
        switch (self.*) {
            .Single => |current_value| {
                var builder = try StringBuilder.init(allocator, current_value, value);
                self.* = .{
                    .Multiple = builder.slices(),
                };
            },

            .Multiple => |items| {
                var builder = StringBuilder.initFromSlices(items);
                try builder.append(allocator, value);

                self.* = .{
                    .Multiple = builder.slices(),
                };
            },
        }
    }

    pub fn trimLeft(self: *Self, index: usize) void {

        switch (self.*) {
            .Single => |value| {

                self.* = .{ .Single = value[index..] };

            },
            .Multiple => |items| {

                var builder = StringBuilder.initFromSlices(items);
                builder.trimLeft(index);

            },
        }
    }

    pub fn trimRight(self: *Self, index: usize) void {

        switch (self.*) {
            .Single => |value| {

                self.* = .{ .Single = value[0..index] };

            },
            .Multiple => |items| {

                var builder = StringBuilder.initFromSlices(items);
                builder.trimRight(index);

                self.* = .{ .Multiple = builder.slices() };

            }
        }
    }

    pub fn toOwnedSlice(self: Self, allocator: Allocator) ![]const u8 {

        switch (self) {
            .Single => |value| {

                return try allocator.dupe(u8, value);

            },
            .Multiple => |items| {

                var builder = StringBuilder.initFromSlices(items);
                return try builder.toOwnedString(allocator);
            },
        }

    }

    pub fn len(self: Self) usize {

        switch (self) {
            .Single => |value| {

                return value.len;

            },
            .Multiple => |items| {

                var builder = StringBuilder.initFromSlices(items);
                return builder.len;
            },
        }        
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


    test "Single slice" {

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


};

pub const StringBuilder = struct {
    const Self = @This();
    const ArrayList = std.ArrayListUnmanaged([]const u8);

    len: usize = 0,
    chunks: ArrayList = .{},

    pub fn init(allocator: Allocator, value_1: []const u8, value_2: []const u8) !StringBuilder {
        var self = StringBuilder{
            .len = 0,
            .chunks = try ArrayList.initCapacity(allocator, 2),
        };

        self.chunks.appendAssumeCapacity(value_1);
        self.chunks.appendAssumeCapacity(value_2);
        return self;
    }

    pub fn initFromSlices(items: [][]const u8) StringBuilder {
        var len: usize = 0;
        for (items) |slice| {
            len += slice.len;
        }

        return .{
            .len = len,
            .chunks = .{ .items = items, .capacity = items.len },
        };
    }

    pub fn slices(self: *const Self) [][]const u8 {
        assert(self.chunks.capacity == self.chunks.items.len);
        return self.chunks.items;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.chunks.deinit(allocator);
        self.len = 0;
    }

    pub fn append(self: *Self, allocator: Allocator, value: []const u8) !void {
        assert(self.chunks.capacity == self.chunks.items.len);

        try self.chunks.resize(allocator, self.chunks.items.len + 1);
        self.chunks.appendAssumeCapacity(value);
        self.len += value.len;
    }

    pub fn trimLeft(self: *Self, index: usize) void {
        self.len -= index;
        var pos: usize = 0;
        for (self.chunks.items) |*slice| {
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
        self.len = index;
        var pos: usize = 0;
        for (self.chunks.items) |*slice| {
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

    pub fn toOwnedString(self: *const Self, allocator: Allocator) ![]const u8 {
        var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, self.len);
        for (self.chunks.items) |slice| {
            try list.appendSlice(allocator, slice);
        }

        return list.toOwnedSlice(allocator);
    }

    test "Trim Left" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        builder.trimLeft(3);
        try testing.expect(builder.len == 7);

        try testing.expectEqualStrings("3456789", try builder.toOwnedString(allocator));
    }

    test "Trim Left all" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const expected = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        try builder.append(allocator, "ABCDE");
        try testing.expect(builder.len == 15);

        try testing.expectEqualStrings(expected, try builder.toOwnedString(allocator));

        const expected_slice = expected[12..];
        builder.trimLeft(12);

        try testing.expectEqual(expected_slice.len, builder.len);

        try testing.expectEqualStrings(expected_slice, try builder.toOwnedString(allocator));
    }

    test "Trim Left clear" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        try builder.append(allocator, "ABCDE");
        try testing.expect(builder.len == 15);

        builder.trimLeft(15);
        try testing.expectEqual(@as(usize, 0), builder.len);

        try testing.expectEqualStrings("", try builder.toOwnedString(allocator));
    }

    test "Trim Right" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        builder.trimRight(7);
        try testing.expect(builder.len == 7);

        try testing.expectEqualStrings("0123456", try builder.toOwnedString(allocator));
    }

    test "Trim Right all" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const expected = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        try builder.append(allocator, "ABCDE");
        try testing.expect(builder.len == 15);

        try testing.expectEqualStrings(expected[0..], try builder.toOwnedString(allocator));

        const expected_slice = expected[0..3];

        builder.trimRight(3);
        try testing.expect(builder.len == expected_slice.len);

        try testing.expectEqualStrings(expected_slice, try builder.toOwnedString(allocator));
    }

    test "Trim Right clear" {
        var arena = ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const expected = "0123456789ABCDE";

        var builder = Self{};
        try builder.append(allocator, "01234");
        try testing.expect(builder.len == 5);

        try builder.append(allocator, "56789");
        try testing.expect(builder.len == 10);

        try builder.append(allocator, "ABCDE");
        try testing.expect(builder.len == 15);

        try testing.expectEqualStrings(expected, try builder.toOwnedString(allocator));

        const expected_slice = expected[0..0];
        builder.trimRight(0);
        try testing.expect(builder.len == expected_slice.len);

        try testing.expectEqualStrings(expected_slice, try builder.toOwnedString(allocator));
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
