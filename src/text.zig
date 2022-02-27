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

const RefCounter = @import("mem.zig").RefCounter;

pub fn fromString(gpa: Allocator, content: []const u8) Allocator.Error!TextReader {
    var ctx = try StringReader.init(gpa, content);
    return ctx.textReader();
}

pub fn fromFile(gpa: Allocator, absolute_path: []const u8, read_buffer_size: u32) Errors!TextReader {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    var stream = try StreamReader(std.fs.File).init(gpa, file, read_buffer_size);
    return stream.textReader();
}

pub const TextReader = struct {

    pub const Result = struct {
        content: []const u8,
        ref_counter: RefCounter,
    };

    const VTable = struct {
        read: fn (ctx: *anyopaque, allocator: Allocator, prepend: []const u8) Errors!Result,
        deinit: fn (ctx: *anyopaque, allocator: Allocator) void,
        finished: fn (ctx: *anyopaque) bool,
    };

    ctx: *anyopaque,
    vtable: *const VTable,

    pub inline fn read(self: TextReader, allocator: Allocator, prepend: []const u8) Errors!Result {
        return self.vtable.read(self.ctx, allocator, prepend);
    }

    pub inline fn deinit(self: TextReader, allocator: Allocator) void {
        self.vtable.deinit(self.ctx, allocator);
    }

    pub inline fn finished(self: TextReader) bool {
        return self.vtable.finished(self.ctx);
    }
};

const StringReader = struct {
    content: ?[]const u8,
    const vtable = TextReader.VTable{
        .read = read,
        .deinit = deinit,
        .finished = finished,
    };

    pub fn init(allocator: Allocator, content: []const u8) Allocator.Error!*StringReader {
        var self = try allocator.create(StringReader);
        self.* = .{
            .content = content,
        };

        return self;
    }

    pub fn textReader(self: *StringReader) TextReader {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn read(ctx: *anyopaque, allocator: Allocator, prepend: []const u8) Errors!TextReader.Result {
        var self = @ptrCast(*StringReader, @alignCast(@alignOf(*StringReader), ctx));
        _ = allocator;
        _ = prepend;

        if (self.content) |content| {
            self.content = null;
            return TextReader.Result {
                .content = content,
                .ref_counter = .{},
            };
        } else {
            return TextReader.Result {
                .content = prepend,
                .ref_counter = .{},
            };
        }
    }

    fn deinit(ctx: *anyopaque, allocator: Allocator) void {
        var self = @ptrCast(*StringReader, @alignCast(@alignOf(*StringReader), ctx));
        allocator.destroy(self);
    }

    fn finished(ctx: *anyopaque) bool {
        var self = @ptrCast(*StringReader, @alignCast(@alignOf(*StringReader), ctx));
        return self.content == null;
    }
};

fn StreamReader(comptime TStream: type) type {
    return struct {
        const Self = @This();
        const vtable = TextReader.VTable{
            .read = read,
            .deinit = deinit,
            .finished = finished,
        };

        stream: TStream,
        eof: bool = false,
        read_buffer_size: u32,

        pub fn init(allocator: Allocator, stream: TStream, read_buffer_size: u32) Allocator.Error!*Self {
            var self = try allocator.create(Self);
            self.* = .{
                .stream = stream,
                .read_buffer_size = read_buffer_size,
            };

            return self;
        }

        pub fn textReader(self: *Self) TextReader {
            return .{
                .ctx = self,
                .vtable = &vtable,
            };
        }

        fn read(ctx: *anyopaque, allocator: Allocator, prepend: []const u8) Errors!TextReader.Result{
            var self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ctx));

            var buffer = try allocator.alloc(u8, self.read_buffer_size + prepend.len);
            errdefer allocator.free(buffer);

            if (prepend.len > 0) {
                std.mem.copy(u8, buffer, prepend);
            }

            var size = try self.stream.read(buffer[prepend.len..]);

            if (size < self.read_buffer_size) {
                const full_size = prepend.len + size;

                assert(full_size < buffer.len);
                buffer = allocator.shrink(buffer, full_size);
                self.eof = true;

            } else {
                self.eof = false;
            }


            return TextReader.Result {
                .content = buffer,
                .ref_counter = try RefCounter.init(allocator, buffer),
            };
        }

        fn deinit(ctx: *anyopaque, allocator: Allocator) void {
            var self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ctx));
            self.stream.close();
            allocator.destroy(self);
        }

        fn finished(ctx: *anyopaque) bool {
            var self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ctx));
            return self.eof;
        }
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

test {
    testing.refAllDecls(@This());
}

test "StreamReader.Slices" {

    const allocator = testing.allocator;

    // Test the StreamReader slicing mechanism
    // In a real use case, the reade_buffer_len is much larger than the amount needed to produce a token
    // So we can parse many tokens on a single read, and read a new slice containing only the lasts unparsed bytes
    //
    // Just 5 chars in our test
    const read_buffer_len: usize = 5;
    //
    //                           Block index
    //              First slice  | Second slice
    //           Block index  |  | |    Third slice
    //                     ↓  ↓  ↓ ↓    ↓
    const content_text = "{{name}}Just static";

    // Creating a temp file
    const path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(path);

    const absolute_file_path = try std.fs.path.join(allocator, &.{ path, "stream_reader_slices.tmp" });
    defer allocator.free(absolute_file_path);

    var file = try std.fs.createFileAbsolute(absolute_file_path, .{ .truncate = true });
    try file.writeAll(content_text);
    file.close();
    defer std.fs.deleteFileAbsolute(absolute_file_path) catch {};

    var reader = try fromFile(allocator, absolute_file_path, read_buffer_len);
    defer reader.deinit(allocator);

    var slice: []const u8 = &.{};
    try testing.expectEqualStrings("", slice);

    // First read
    // We got a slice with "read_buffer_len" size to parse
    var result_1 = try reader.read(allocator, slice);
    defer result_1.ref_counter.free(allocator);
    slice = result_1.content;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqual(read_buffer_len, slice.len);
    try testing.expectEqualStrings("{{nam", slice);

    // Second read,
    // The parser produces the first token "{{" and reaches the EOF of this slice
    // We need more data, the previous slice was parsed until the block_index = 2,
    // so we expect the next read to return the remaining bytes plus new 5 bytes read
    var result_2 = try reader.read(allocator, slice[2..]);
    defer result_2.ref_counter.free(allocator);
    slice = result_2.content;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqualStrings("name}}Ju", slice);

    // Third read,
    // We parsed a next token '}}' at block_index = 6,
    // so we need another slice
    var result_3 = try reader.read(allocator, slice[6..]);
    defer result_3.ref_counter.free(allocator);
    slice = result_3.content;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqualStrings("Just st", slice);

    // Last read,
    // Nothing was parsed,
    var result_4 = try reader.read(allocator, slice);
    defer result_4.ref_counter.free(allocator);
    slice = result_4.content;

    try testing.expectEqual(true, reader.finished());
    try testing.expectEqualStrings("Just static", slice);

    // After that, EOF
    var result_5 = try reader.read(allocator, slice);
    defer result_5.ref_counter.free(allocator);
    slice = result_5.content;

    try testing.expectEqual(true, reader.finished());
    try testing.expectEqualStrings("Just static", slice);
}
