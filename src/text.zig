/// String and text manipulation helpers
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

const OpenError = std.fs.File.OpenError;
const ReadError = std.fs.File.ReadError;
const FileError = OpenError || ReadError;
const Errors = Allocator.Error || FileError;

pub fn fromString(arena: Allocator, content: []const u8) Allocator.Error!TextReader {
    var ctx = try StringReader.init(arena, content);
    return ctx.textReader();
}

pub fn fromFile(arena: Allocator, absolute_path: []const u8) Errors!TextReader {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    var stream = try StreamReader(std.fs.File).init(arena, file);
    return stream.textReader();
}

pub const TextReader = struct {
    const ReadFn = fn (ctx: *anyopaque, ref_slice: *[]const u8, block_index: usize) Errors!ReaderResult;
    const CloseFn = fn (ctx: *anyopaque) void;
    const VTable = struct {
        read: ReadFn,
        close: CloseFn,
    };

    pub const ReaderResult = enum {
        Eof,
        LastPart,
        Continue,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn read(self: TextReader, ref_slice: *[]const u8, block_index: usize) Errors!ReaderResult {
        return self.vtable.read(self.ctx, ref_slice, block_index);
    }

    pub fn close(self: TextReader) void {
        self.vtable.close(self.ctx);
    }
};

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

    pub fn charAt(self: *const Self, index: usize) u8 {
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

        return '\x00';
    }

    pub fn clear(self: *Self) void {
        self.root = null;
        self.current = null;
    }

    pub inline fn isEmpty(self: *const Self) bool {
        return self.root == null;
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

const StringReader = struct {
    content: ?[]const u8,
    const vtable = TextReader.VTable{
        .read = read_fn,
        .close = close_fn,
    };

    pub fn init(arena: Allocator, content: []const u8) Allocator.Error!*StringReader {
        var self = try arena.create(StringReader);
        self.* = .{ .content = content };

        return self;
    }

    pub fn textReader(self: *StringReader) TextReader {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn read_fn(ctx: *anyopaque, ref_slice: *[]const u8, block_index: usize) Errors!TextReader.ReaderResult {
        const alignment = @alignOf(*StringReader);
        var self = @ptrCast(*StringReader, @alignCast(alignment, ctx));
        _ = block_index;

        if (self.content) |content| {
            self.content = null;
            ref_slice.* = content;
            return .LastPart;
        } else {
            return .Eof;
        }
    }

    fn close_fn(ctx: *anyopaque) void {
        _ = ctx;
    }
};

fn StreamReader(comptime TStream: type) type {
    return struct {
        const BUFFER_SIZE = 4096;
        const Self = @This();
        const vtable = TextReader.VTable{
            .read = read_fn,
            .close = close_fn,
        };

        arena: Allocator,
        stream: TStream,

        pub fn init(arena: Allocator, stream: TStream) Allocator.Error!*Self {
            var self = try arena.create(Self);
            self.* = .{
                .arena = arena,
                .stream = stream,
            };

            return self;
        }

        pub fn textReader(self: *Self) TextReader {
            return .{
                .ctx = self,
                .vtable = &vtable,
            };
        }

        fn read_fn(ctx: *anyopaque, ref_slice: *[]const u8, block_index: usize) Errors!TextReader.ReaderResult {
            var self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ctx));

            const start_index = ref_slice.*.len - block_index + 1;
            var buffer = try self.arena.alloc(u8, BUFFER_SIZE + start_index);
            if (start_index > 0) {
                std.mem.copy(u8, buffer, ref_slice.*[block_index..]);
            }

            var size = try self.stream.read(buffer[start_index..]);
            if (size == 0) {
                self.arena.free(buffer[start_index..]);
                return .Eof;
            } else if (size < BUFFER_SIZE) {
                self.arena.free(buffer[start_index + size ..]);
                ref_slice.* = buffer[0..start_index + size];
                return .LastPart;
            } else {
                ref_slice.* = buffer;
                return .Continue;
            }
        }

        //ABC01234

        fn close_fn(ctx: *anyopaque) void {
            var self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ctx));
            self.stream.close();
        }
    };
}

test {
    testing.refAllDecls(@This());
}
