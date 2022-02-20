const std = @import("std");

const parsing = @import("parsing.zig");
const TextBlock = parsing.TextBlock;
const BlockType = parsing.BlockType;

const assert = std.debug.assert;
const testing = std.testing;

const Self = @This();

block_type: BlockType,
text_block: TextBlock,
prev_node: ?*Self = null,
children: ?[]const *Self = null,

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
