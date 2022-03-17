const std = @import("std");
const Allocator = std.mem.Allocator;

const parsing = @import("parsing.zig");
const TextBlock = parsing.TextBlock;
const BlockType = parsing.BlockType;

const mem = @import("../mem.zig");
const RefCountedSlice = mem.RefCountedSlice;

const assert = std.debug.assert;
const testing = std.testing;

const Self = @This();

block_type: BlockType,
text_block: TextBlock,
inner_text: ?RefCountedSlice = null, 
prev_node: ?*Self = null,
children: ?[]*Self = null,

///
/// A node holds a RefCounter to the underlying text buffer
/// This function unref a list of nodes and free the buffer if no other Node references it
pub fn unRefMany(allocator: Allocator, nodes: ?[]*Self) void {
    if (nodes) |items| {
        for (items) |item| {
            item.unRef(allocator);
        }
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
    if (self.block_type == .StaticText) {
        if (self.prev_node) |prev_node| {
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
    if (self.block_type == .StaticText) {
        if (self == last_node) return;

        var node = last_node;
        while (node != self) {
            assert(node.block_type != .StaticText);
            assert(node.prev_node != null);

            if (!node.block_type.canBeStandAlone()) {
                return;
            } else {
                node = node.prev_node.?;
            }
        }

        node.text_block.trimRight();
    }
}

pub fn getIndentation(self: *const Self) ?[]const u8 {
    return switch (self.block_type) {
        .Partial, .Parent => getPreviousNodeIndentation(self.prev_node),
        else => null,
    };
}

fn trimPreviousNodesRight(parent_node: ?*Self) bool {
    if (parent_node) |node| {
        if (node.block_type == .StaticText) {
            switch (node.text_block.right_trimming) {
                .AllowTrimming => |trimming| {

                    // Non standalone tags must check the previous node
                    const can_trim = trimming.stand_alone or trimPreviousNodesRight(node.prev_node);
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
            return trimPreviousNodesRight(node.prev_node);
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
    if (parent_node) |node| {
        return switch (node.block_type) {
            .StaticText => node.text_block.indentation,
            else => getPreviousNodeIndentation(node.prev_node),
        };
    } else {
        return null;
    }
}
