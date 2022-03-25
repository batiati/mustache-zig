const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../mustache.zig");
const Options = mustache.Options;

const memory = @import("../memory.zig");

const parsing = @import("parsing.zig");
const BlockType = parsing.BlockType;

pub fn Node(comptime options: Options) type {
    const RefCountedSlice = memory.RefCountedSlice(options);
    const TextBlock = parsing.TextBlock(options);

    const has_trimming = options.features.preseve_line_breaks_and_indentation;

    return struct {
        const Self = @This();

        block_type: BlockType,
        text_block: TextBlock,
        inner_text: ?RefCountedSlice = null,

        ///
        /// Pointers used to navigate during the parse process
        link: struct {

            ///
            /// Previous node in the same order they appear on the template text
            /// It's used for calculating trimming, indentation and stand alone tags
            prev: if (has_trimming) ?*Self else void = if (has_trimming) null else {},

            ///
            /// Next node on the same hierarchy
            next_sibling: ?*Self = null,

            ///
            /// First child node
            child: ?*Self = null,
        } = .{},

        pub const Iterator = struct {
            first: ?*Self,
            current: ?*Self,

            pub fn next(self: *@This()) ?*Self {
                if (self.current) |current| {
                    defer self.current = current.link.next_sibling;
                    return current;
                } else {
                    return null;
                }
            }

            pub fn reset(self: *@This()) void {
                self.current = self.first;
            }

            pub fn len(self: @This()) usize {
                const counter = struct {
                    fn action(current: ?*Self, count: usize) usize {
                        if (current) |value| {
                            return action(value.link.next_sibling, count + 1);
                        } else {
                            return count;
                        }
                    }
                }.action;

                return counter(self.current, 0);
            }
        };

        pub fn children(self: *Self) Iterator {
            return .{
                .first = self.link.child,
                .current = self.link.child,
            };
        }

        pub fn siblings(self: *Self) Iterator {
            return .{
                .first = self,
                .current = self,
            };
        }

        ///
        /// A node holds a RefCounter to the underlying text buffer
        /// This function unref a list of nodes and free the buffer if no other Node references it
        pub fn unRefMany(allocator: Allocator, iterator: *Iterator) void {
            iterator.reset();
            while (iterator.next()) |item| {
                item.unRef(allocator);
            }
        }

        ///
        /// A node holds a RefCounter to the underlying text buffer
        /// This functions unref the counter and free the buffer if no other Node references it
        pub fn unRef(self: *Self, allocator: Allocator) void {
            self.text_block.unRef(allocator);
            if (self.inner_text) |*inner_text| {
                inner_text.ref_counter.free(allocator);
            }
        }

        pub fn trimStandAlone(self: *Self) void {
            if (!options.features.preseve_line_breaks_and_indentation) return;

            if (self.block_type == .StaticText) {
                if (self.link.prev) |prev_node| {
                    switch (self.text_block.left_trimming) {
                        .PreserveWhitespaces => {},
                        .Trimmed => assert(false),
                        .AllowTrimming => {
                            const can_trim = trimPreviousNodesRight(prev_node);

                            if (can_trim) {
                                self.text_block.trimLeft();
                            } else {
                                self.text_block.left_trimming = .PreserveWhitespaces;
                            }
                        },
                    }
                }
            }
        }

        pub fn trimLast(self: *Self, last_node: *Self) void {
            if (!options.features.preseve_line_breaks_and_indentation) return;

            if (self.block_type == .StaticText) {
                if (self == last_node) return;

                var node = last_node;
                while (node != self) {
                    assert(node.block_type != .StaticText);
                    assert(node.link.prev != null);

                    if (!node.block_type.canBeStandAlone()) {
                        return;
                    } else {
                        node = node.link.prev.?;
                    }
                }

                node.text_block.trimRight();
            }
        }

        pub fn getIndentation(self: *const Self) ?[]const u8 {
            return if (options.features.preseve_line_breaks_and_indentation)
                switch (self.block_type) {
                    .Partial, .Parent => getPreviousNodeIndentation(self.link.prev),
                    else => null,
                }
            else
                null;
        }

        fn trimPreviousNodesRight(parent_node: ?*Self) bool {
            if (!options.features.preseve_line_breaks_and_indentation) return false;

            if (parent_node) |node| {
                if (node.block_type == .StaticText) {
                    switch (node.text_block.right_trimming) {
                        .AllowTrimming => |trimming| {

                            // Non standalone tags must check the previous node
                            const can_trim = trimming.stand_alone or trimPreviousNodesRight(node.link.prev);
                            if (can_trim) {
                                node.text_block.trimRight();
                                return true;
                            } else {
                                node.text_block.right_trimming = .PreserveWhitespaces;

                                // If the space is preserved, it is not considered indentation
                                node.text_block.indentation = null;
                                return false;
                            }
                        },
                        .Trimmed => return true,
                        .PreserveWhitespaces => return false,
                    }
                } else if (node.block_type.canBeStandAlone()) {
                    // Depends on the previous node
                    return trimPreviousNodesRight(node.link.prev);
                } else {
                    // Interpolation tags must preserve whitespaces
                    return false;
                }
            } else {
                // No parent node, the first node can always be considered stand-alone
                return true;
            }
        }

        fn getPreviousNodeIndentation(parent_node: ?*const Self) ?[]const u8 {
            if (!options.features.preseve_line_breaks_and_indentation) return null;

            if (parent_node) |node| {
                return switch (node.block_type) {
                    .StaticText => node.text_block.indentation,
                    else => getPreviousNodeIndentation(node.link.prev),
                };
            } else {
                return null;
            }
        }
    };
}
