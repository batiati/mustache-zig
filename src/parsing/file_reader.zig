const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const ref_counter = @import("ref_counter.zig");

const File = std.fs.File;

pub fn FileReader(comptime options: TemplateOptions) type {
    const read_buffer_size = switch (options.source) {
        .Stream => |stream| stream.read_buffer_size,
        .String => return void,
    };

    const RefCounter = ref_counter.RefCounter(options);
    const RefCountedSlice = ref_counter.RefCountedSlice(options);

    return struct {
        const Self = @This();

        pub const OpenError = std.fs.File.OpenError;
        pub const Error = Allocator.Error || std.fs.File.ReadError;

        file: File,
        eof: bool = false,

        pub fn init(absolute_path: []const u8) OpenError!Self {
            var file = try std.fs.openFileAbsolute(absolute_path, .{});
            return Self{
                .file = file,
            };
        }

        pub fn read(self: *Self, allocator: Allocator, prepend: []const u8) Error!RefCountedSlice {
            var buffer = try allocator.alloc(u8, read_buffer_size + prepend.len);
            errdefer allocator.free(buffer);

            if (prepend.len > 0) {
                std.mem.copy(u8, buffer, prepend);
            }

            var size = try self.file.read(buffer[prepend.len..]);

            if (size < read_buffer_size) {
                const full_size = prepend.len + size;

                assert(full_size < buffer.len);
                buffer = allocator.shrink(buffer, full_size);
                self.eof = true;
            } else {
                self.eof = false;
            }

            return RefCountedSlice{
                .slice = buffer,
                .ref_counter = try RefCounter.create(allocator, buffer),
            };
        }

        pub fn deinit(self: *Self) void {
            self.file.close();
        }

        pub inline fn finished(self: *Self) bool {
            return self.eof;
        }
    };
}

test "FileReader.Slices" {
    const allocator = testing.allocator;

    // Test the FileReader slicing mechanism
    // In a real use case, the read_buffer_len is much larger than the amount needed to produce a token
    // So we can parse many tokens on a single read, and read a new slice containing only the last unparsed bytes
    //
    // Just 5 chars in our test
    const SlicedReader = FileReader(.{ .source = .{ .Stream = .{ .read_buffer_size = 5 } }, .output = .Parse });

    //
    //                           Block index
    //              First slice  | Second slice
    //           Block index  |  | |    Third slice
    //                     ↓  ↓  ↓ ↓    ↓
    const content_text = "{{name}}Just static";

    // Creating a temp file
    const path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(path);

    const absolute_file_path = try std.fs.path.join(allocator, &.{ path, "file_reader_slices.tmp" });
    defer allocator.free(absolute_file_path);

    var file = try std.fs.createFileAbsolute(absolute_file_path, .{ .truncate = true });
    try file.writeAll(content_text);
    file.close();
    defer std.fs.deleteFileAbsolute(absolute_file_path) catch {};

    var reader = try SlicedReader.init(absolute_file_path);
    defer reader.deinit();

    var slice: []const u8 = &.{};
    try testing.expectEqualStrings("", slice);

    // First read
    // We got a slice with "read_buffer_len" size to parse
    var result_1 = try reader.read(allocator, slice);
    defer result_1.ref_counter.unRef(allocator);
    slice = result_1.slice;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqual(@as(usize, 5), slice.len);
    try testing.expectEqualStrings("{{nam", slice);

    // Second read,
    // The parser produces the first token "{{" and reaches the EOF of this slice
    // We need more data, the previous slice was parsed until the block_index = 2,
    // so we expect the next read to return the remaining bytes plus new 5 bytes read
    var result_2 = try reader.read(allocator, slice[2..]);
    defer result_2.ref_counter.unRef(allocator);
    slice = result_2.slice;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqualStrings("name}}Ju", slice);

    // Third read,
    // We parsed a next token '}}' at block_index = 6,
    // so we need another slice
    var result_3 = try reader.read(allocator, slice[6..]);
    defer result_3.ref_counter.unRef(allocator);
    slice = result_3.slice;

    try testing.expectEqual(false, reader.finished());
    try testing.expectEqualStrings("Just st", slice);

    // Last read,
    // Nothing was parsed,
    var result_4 = try reader.read(allocator, slice);
    defer result_4.ref_counter.unRef(allocator);
    slice = result_4.slice;

    try testing.expectEqual(true, reader.finished());
    try testing.expectEqualStrings("Just static", slice);

    // After that, EOF
    var result_5 = try reader.read(allocator, slice);
    defer result_5.ref_counter.unRef(allocator);
    slice = result_5.slice;

    try testing.expectEqual(true, reader.finished());
    try testing.expectEqualStrings("Just static", slice);
}
