const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

const OpenError = std.fs.File.OpenError;
const ReadError = std.fs.File.ReadError;
const FileError = OpenError || ReadError;
pub const Errors = Allocator.Error || FileError;

const RefCounter = @import("../mem.zig").RefCounter;
const File = std.fs.File;

const Self = @This();

pub const Result = struct {
    content: []const u8,
    ref_counter: RefCounter,
};

file: File,
eof: bool = false,
read_buffer_size: usize,

pub fn initFromPath(allocator: Allocator, absolute_path: []const u8, read_buffer_size: usize) Errors!*Self {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    return Self.init(allocator, file, read_buffer_size);
}

pub fn init(allocator: Allocator, file: File, read_buffer_size: usize) Allocator.Error!*Self {
    var self = try allocator.create(Self);
    self.* = .{
        .file = file,
        .read_buffer_size = read_buffer_size,
    };

    return self;
}

pub fn read(self: *Self, allocator: Allocator, prepend: []const u8) Errors!Result {
    var buffer = try allocator.alloc(u8, self.read_buffer_size + prepend.len);
    errdefer allocator.free(buffer);

    if (prepend.len > 0) {
        std.mem.copy(u8, buffer, prepend);
    }

    var size = try self.file.read(buffer[prepend.len..]);

    if (size < self.read_buffer_size) {
        const full_size = prepend.len + size;

        assert(full_size < buffer.len);
        buffer = allocator.shrink(buffer, full_size);
        self.eof = true;
    } else {
        self.eof = false;
    }

    return Result{
        .content = buffer,
        .ref_counter = try RefCounter.init(allocator, buffer),
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.file.close();
    allocator.destroy(self);
}

pub fn finished(self: *Self) bool {
    return self.eof;
}

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

    var reader = try initFromPath(allocator, absolute_file_path, read_buffer_len);
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
