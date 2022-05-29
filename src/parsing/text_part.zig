const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const memory = @import("memory.zig");

const parsing = @import("parsing.zig");
const PartType = parsing.PartType;
const Delimiters = parsing.Delimiters;

pub fn TextPart(comptime options: TemplateOptions) type {
    const RefCounter = memory.RefCounter(options);
    const RefCountedSlice = memory.RefCountedSlice(options);
    const TrimmingIndex = parsing.TrimmingIndex(options);

    return struct {
        const Self = @This();

        part_type: PartType,
        is_stand_alone: bool,
        content: []const u8,
        ref_counter: RefCounter,

        indentation: RefCountedSlice = RefCountedSlice.empty,

        /// The line and column on the template source
        /// Used mostly for error messages
        source: struct {
            lin: u32,
            col: u32,
        },

        /// Trimming rules
        trimming: struct {
            left: TrimmingIndex = .PreserveWhitespaces,
            right: TrimmingIndex = .PreserveWhitespaces,
        } = .{},

        pub inline fn unRef(self: *Self, allocator: Allocator) void {
            self.ref_counter.free(allocator);
            self.indentation.ref_counter.free(allocator);
        }

        /// Processes the trimming rules for the right side of the slice
        pub fn trimRight(self: *Self) ?RefCountedSlice {
            return switch (self.trimming.right) {
                .PreserveWhitespaces, .Trimmed => null,
                .AllowTrimming => |right_trimming| indentation: {
                    const content = self.content;

                    if (right_trimming.index == 0) {
                        self.content = &.{};
                    } else if (right_trimming.index < content.len) {
                        self.content = content[0..right_trimming.index];
                    }

                    self.trimming.right = .Trimmed;

                    if (right_trimming.index + 1 >= content.len) {
                        break :indentation null;
                    } else {
                        break :indentation RefCountedSlice{
                            .content = content[right_trimming.index..],
                            .ref_counter = self.ref_counter.ref(),
                        };
                    }
                },
            };
        }

        /// Processes the trimming rules for the left side of the slice
        pub fn trimLeft(self: *Self) void {
            switch (self.trimming.left) {
                .PreserveWhitespaces, .Trimmed => {},
                .AllowTrimming => |left_trimming| {
                    const content = self.content;

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
                        .AllowTrimming => |right_trimming| {
                            self.trimming.right = .{
                                .AllowTrimming = .{
                                    .index = right_trimming.index - left_trimming.index - 1,
                                    .stand_alone = right_trimming.stand_alone,
                                },
                            };
                        },

                        else => {},
                    }

                    if (left_trimming.index >= content.len - 1) {
                        self.content = &.{};
                    } else {
                        self.content = content[left_trimming.index + 1 ..];
                    }

                    self.trimming.left = .Trimmed;
                },
            }
        }
    };
}
