const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const Element = mustache.Element;

const ref_counter = @import("ref_counter.zig");

const parsing = @import("parsing.zig");
const Delimiters = parsing.Delimiters;
const IndexBookmark = parsing.IndexBookmark;

pub fn Node(comptime options: TemplateOptions) type {
    const RefCounter = ref_counter.RefCounter(options);
    const has_trimming = options.features.preseve_line_breaks_and_indentation;
    const allow_lambdas = options.features.lambdas == .enabled;

    return struct {
        const Self = @This();

        pub const List = std.ArrayListUnmanaged(Self);
        pub const TextPart = parsing.TextPart(options);

        index: u32 = 0,
        identifier: ?[]const u8,
        text_part: TextPart,

        children_count: u32 = 0,
        delimiters: ?Delimiters = null,

        inner_text: if (allow_lambdas) struct {
            content: ?[]const u8 = null,
            ref_counter: RefCounter = .{},
            bookmark: ?IndexBookmark = null,
        } else void = if (allow_lambdas) .{} else {},

        pub fn unRef(self: *Self, allocator: Allocator) void {
            if (comptime options.isRefCounted()) {
                self.text_part.unRef(allocator);
                if (allow_lambdas) {
                    self.inner_text.ref_counter.unRef(allocator);
                }
            }
        }

        pub fn trimStandAlone(self: *Self, list: *List) void {
            if (comptime !has_trimming) return;

            var text_part = &self.text_part;
            if (text_part.part_type == .static_text) {
                switch (text_part.trimming.left) {
                    .preserve_whitespaces => {},
                    .trimmed => assert(false),
                    .allow_trimming => {
                        const can_trim = trimPreviousNodesRight(list, self.index);
                        if (can_trim) {
                            text_part.trimLeft();
                        } else {
                            text_part.trimming.left = .preserve_whitespaces;
                        }
                    },
                }
            }
        }

        pub fn trimLast(self: *Self, allocator: Allocator, nodes: *List) void {
            if (comptime !has_trimming) return;
            if (nodes.items.len == 0) return;

            var text_part = &self.text_part;
            if (text_part.part_type == .static_text) {
                if (!text_part.is_stand_alone) {
                    var index = nodes.items.len - 1;
                    if (self.index == index) return;

                    assert(self.index < index);

                    while (self.index < index) : (index -= 1) {
                        const node = &nodes.items[index];

                        if (!node.text_part.is_stand_alone) {
                            return;
                        }
                    }
                }

                var maybe_indentation = text_part.trimRight();
                if (maybe_indentation) |*indentation| {
                    if (self.index == nodes.items.len - 1) {
                        // The last tag can't produce any meaningful indentation, so we discard it
                        indentation.ref_counter.unRef(allocator);
                    } else {
                        var next_node = &nodes.items[self.index + 1];
                        next_node.text_part.indentation = indentation.*;
                    }
                }
            }
        }

        pub fn getIndentation(self: *const Self) ?[]const u8 {
            return if (comptime has_trimming)
                switch (self.text_part.part_type) {
                    .partial,
                    .parent,
                    => if (self.text_part.indentation) |indentation| indentation.slice else null,
                    else => null,
                }
            else
                null;
        }

        pub fn getInnerText(self: *const Self) ?[]const u8 {
            if (comptime allow_lambdas) {
                if (self.inner_text.content) |node_inner_text| {
                    return node_inner_text;
                }
            }

            return null;
        }

        fn trimPreviousNodesRight(nodes: *List, index: u32) bool {
            if (comptime !has_trimming) return false;

            if (index > 0) {
                var current_node = &nodes.items[index];
                const prev_index = index - 1;
                var node = &nodes.items[prev_index];
                var text_part = &node.text_part;

                if (text_part.part_type == .static_text) {
                    switch (text_part.trimming.right) {
                        .allow_trimming => |trimming| {

                            // Non standalone tags must check the previous node
                            const can_trim = trimming.stand_alone or trimPreviousNodesRight(nodes, prev_index);
                            if (can_trim) {
                                if (text_part.trimRight()) |indentation| {
                                    current_node.text_part.indentation = indentation;
                                }

                                return true;
                            } else {
                                text_part.trimming.right = .preserve_whitespaces;
                                return false;
                            }
                        },
                        .trimmed => return true,
                        .preserve_whitespaces => return false,
                    }
                } else if (text_part.is_stand_alone) {
                    // Depends on the previous node
                    return trimPreviousNodesRight(nodes, prev_index);
                } else {
                    // Interpolation tags must preserve whitespaces
                    return false;
                }
            } else {
                // No parent node, the first node can always be considered stand-alone
                return true;
            }
        }
    };
}
