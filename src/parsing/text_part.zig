const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const ref_counter = @import("ref_counter.zig");

const parsing = @import("parsing.zig");
const PartType = parsing.PartType;
const Delimiters = parsing.Delimiters;

pub fn TextPart(comptime options: TemplateOptions) type {
    const RefCountedSlice = ref_counter.RefCountedSlice(options);
    const TrimmingIndex = parsing.TrimmingIndex(options);

    return struct {
        const Self = @This();

        part_type: PartType,
        is_stand_alone: bool,

        /// Slice containing the content for this TextPart
        /// When parsing from streams, RefCounter holds a reference to the underlying read buffer, otherwise the RefCounter is a no-op.
        content: RefCountedSlice,

        /// Slice containing the indentation for this TextPart
        /// When parsing from streams, RefCounter holds a reference to the underlying read buffer, otherwise the RefCounter is a no-op.
        indentation: ?RefCountedSlice = null,

        /// The line and column on the template source
        /// Used mostly for error messages
        source: struct {
            lin: u32,
            col: u32,
        },

        /// Trimming rules
        trimming: struct {
            left: TrimmingIndex = .preserve_whitespaces,
            right: TrimmingIndex = .preserve_whitespaces,
        } = .{},

        pub inline fn unRef(self: *Self, allocator: Allocator) void {
            self.content.ref_counter.unRef(allocator);

            if (self.indentation) |*indentation| {
                indentation.ref_counter.unRef(allocator);
            }
        }

        /// Determines if this TextPart is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.content.slice.len == 0;
        }

        /// Processes the trimming rules for the right side of the slice
        pub fn trimRight(self: *Self) ?RefCountedSlice {
            return switch (self.trimming.right) {
                .preserve_whitespaces, .trimmed => null,
                .allow_trimming => |right_trimming| indentation: {
                    const content = self.content.slice;

                    if (right_trimming.index == 0) {
                        self.content.slice = &.{};
                    } else if (right_trimming.index < content.len) {
                        self.content.slice = content[0..right_trimming.index];
                    }

                    self.trimming.right = .trimmed;

                    if (right_trimming.index + 1 >= content.len) {
                        break :indentation null;
                    } else {
                        break :indentation RefCountedSlice{
                            .slice = content[right_trimming.index..],
                            .ref_counter = self.content.ref_counter.ref(),
                        };
                    }
                },
            };
        }

        /// Processes the trimming rules for the left side of the slice
        pub fn trimLeft(self: *Self) void {
            switch (self.trimming.left) {
                .preserve_whitespaces, .trimmed => {},
                .allow_trimming => |left_trimming| {
                    const content = self.content.slice;

                    // Update the trim-right index and indentation after trimming left
                    // BEFORE:
                    //                 2      7
                    //                 ↓      ↓
                    //const value = "  \nABC\n  "
                    //
                    // AFTER:
                    //                    4
                    //                    ↓
                    //const value = "ABC\n  "

                    switch (self.trimming.right) {
                        .allow_trimming => |right_trimming| {
                            self.trimming.right = .{
                                .allow_trimming = .{
                                    .index = right_trimming.index - left_trimming.index - 1,
                                    .stand_alone = right_trimming.stand_alone,
                                },
                            };
                        },

                        else => {},
                    }

                    if (left_trimming.index >= content.len - 1) {
                        self.content.slice = &.{};
                    } else {
                        self.content.slice = content[left_trimming.index + 1 ..];
                    }

                    self.trimming.left = .trimmed;
                },
            }
        }

        pub fn parseDelimiters(self: *const Self) ?Delimiters {

            // Delimiters are the only case of match closing tags {{= and =}}
            // Validate if the content ends with the proper "=" symbol before parsing the delimiters
            var content = self.content.slice;
            const last_index = content.len - 1;
            if (content[last_index] != @intFromEnum(PartType.delimiters)) return null;

            content = content[0..last_index];
            var iterator = std.mem.tokenize(u8, content, " \t");

            const starting_delimiter = iterator.next() orelse return null;
            const ending_delimiter = iterator.next() orelse return null;
            if (iterator.next() != null) return null;

            return Delimiters{
                .starting_delimiter = starting_delimiter,
                .ending_delimiter = ending_delimiter,
            };
        }
    };
}
