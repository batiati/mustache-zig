/// TextBlock is some slice of string containing information about how it appears on the template source.
/// Each TextBlock is produced by the TextScanner, it is the first stage of the parsing process,
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
    const TrimmingIndex = parsing.TrimmingIndex(options);

    return struct {
        const Self = @This();

        content: []const u8,

        part_type: PartType,

        /// A ref counter for the buffer that holds this strings
        ref_counter: RefCounter,

        /// The line on the template source
        /// Used mostly for error messages
        lin: u32,

        /// The column on the template source
        /// Used mostly for error messages
        col: u32,

        /// Trimming rules for the left side of the slice
        left_trimming: TrimmingIndex = .PreserveWhitespaces,

        /// Trimming rules for the right side of the slice
        right_trimming: TrimmingIndex = .PreserveWhitespaces,

        /// Indentation presented on this text block
        /// All indentation must be propagated to the child elements
        indentation: ?[]const u8 = null,

        pub inline fn unRef(self: *Self, allocator: Allocator) void {
            self.ref_counter.free(allocator);
        }

        /// Processes the trimming rules for the right side of the slice
        pub fn trimRight(self: *Self) void {
            switch (self.right_trimming) {
                .PreserveWhitespaces, .Trimmed => {},
                .AllowTrimming => |right_trimming| {
                    const content = self.content;

                    if (right_trimming.index == 0) {
                        self.content = &.{};
                        // TODO: unref??
                    } else if (right_trimming.index < content.len) {
                        self.content = content[0..right_trimming.index];
                    }

                    if (right_trimming.index + 1 >= content.len) {
                        self.indentation = null;
                    } else {
                        self.indentation = content[right_trimming.index..];
                    }

                    self.right_trimming = .Trimmed;
                },
            }
        }

        /// Processes the trimming rules for the left side of the slice
        pub fn trimLeft(self: *Self) void {
            switch (self.left_trimming) {
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

                    switch (self.right_trimming) {
                        .AllowTrimming => |right_trimming| {
                            self.right_trimming = .{
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
                        //TODO: unref??
                    } else {
                        self.content = content[left_trimming.index + 1 ..];
                    }

                    self.left_trimming = .Trimmed;
                },
            }
        }
    };
}
