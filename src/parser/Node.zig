const std = @import("std");

const scanner = @import("scanner.zig");
const TextBlock = scanner.TextBlock;
const BlockType = scanner.BlockType;

const assert = std.debug.assert;
const testing = std.testing;

const Self = @This();

block_type: BlockType,
text_block: TextBlock,
prev_node: ?*Self = null,
children: ?[]const *Self = null,

pub fn trimStandAlone(self: *Self) void {

    // Lines containing tags without any static text or interpolation
    // must be fully removed from the rendered result
    //
    // Examples:
    //
    // 1. TRIM LEFT stand alone tags
    //
    //                                            ┌ any white space after the tag must be TRIMMED,
    //                                            ↓ including the EOL
    // var template_text = \\{{! Comments block }}
    //                     \\Hello World
    //
    // 2. TRIM RIGHT stand alone tags
    //
    //                            ┌ any white space before the tag must be trimmed,
    //                            ↓
    // var template_text = \\      {{! Comments block }}
    //                     \\Hello World
    //
    // 3. PRESERVE interpolation tags
    //
    //                                     ┌ all white space and the line break after that must be PRESERVED,
    //                                     ↓
    // var template_text = \\      {{Name}}
    //                     \\      {{Address}}
    //                            ↑
    //                            └ all white space before that must be PRESERVED,

    if (self.block_type == .StaticText) {
        if (self.prev_node) |prev_node| {
            if (trimRight(prev_node)) {
                _ = self.text_block.trimLeft();
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

        _ = node.text_block.trimRight();
    }
}

fn trimRight(parent_node: ?*Self) bool {
    if (parent_node) |node| {
        if (node.block_type == .StaticText) {
            return node.text_block.trimRight();
        } else if (node.block_type.canBeStandAlone()) {
            // Depends on the previous node
            return trimRight(node.prev_node);
        } else {
            // Interpolation tags must preserve whitespaces
            return false;
        }
    } else {
        // No parent node, the first node can trim Right
        return true;
    }
}