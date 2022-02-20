const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const ParseErrors =  mustache.template.ParseErrors;

const scanner = @import("scanner.zig");
const BlockType = scanner.BlockType;
const TextBlock = scanner.TextBlock;
const Node = scanner.Node;

const assert = std.debug.assert;
const testing = std.testing;

const Self = @This();

parent: ?*Self,
delimiters: Delimiters,
current_node: ?*Node,
list: std.ArrayListUnmanaged(*Node) = .{},

pub fn init(arena: Allocator, delimiters: Delimiters) Allocator.Error!*Self {
    var self = try arena.create(Self);
    self.* = .{
        .parent = null,
        .delimiters = delimiters,
        .current_node = null,
    };

    return self;
}

pub fn addNode(self: *Self, arena: Allocator, block_type: BlockType, text_block: TextBlock) Allocator.Error!void {
    var node = try arena.create(Node);
    node.* = .{
        .block_type = block_type,
        .text_block = text_block,
        .prev_node = self.current_node,
    };

    try self.list.append(arena, node);
    self.current_node = node;
}

pub fn nextLevel(self: *Self, arena: Allocator) Allocator.Error!*Self {
    var next_level = try arena.create(Self);

    next_level.* = .{
        .parent = self,
        .delimiters = self.delimiters,
        .current_node = self.current_node,
    };

    return next_level;
}

pub fn endLevel(self: *Self, arena: Allocator) ParseErrors!*Self {
    var prev_level = self.parent orelse return ParseErrors.UnexpectedCloseSection;
    var parent_node = prev_level.current_node orelse return ParseErrors.UnexpectedCloseSection;

    parent_node.children = self.list.toOwnedSlice(arena);

    prev_level.current_node = self.current_node;
    return prev_level;
}

test "Level" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var level = try Self.init(allocator, .{});
    try testing.expect(level.current_node == null);

    try level.addNode(allocator, undefined, undefined);
    try testing.expect(level.current_node != null);
    var n1 = level.current_node.?;
    try testing.expect(n1.prev_node == null);

    try level.addNode(allocator, undefined, undefined);
    try testing.expect(level.current_node != null);
    var n2 = level.current_node.?;
    try testing.expect(n2.prev_node != null);
    try testing.expectEqual(n1, n2.prev_node.?);

    var level2 = try level.nextLevel(allocator);
    try testing.expect(level2.current_node != null);
    try testing.expectEqual(level2.current_node.?, n2);

    try level2.addNode(allocator, undefined, undefined);
    try testing.expect(level2.current_node != null);
    var n3 = level2.current_node.?;
    try testing.expect(n3.prev_node != null);
    try testing.expectEqual(n2, n3.prev_node.?);

    try level2.addNode(allocator, undefined, undefined);
    try testing.expect(level2.current_node != null);
    var n4 = level2.current_node.?;
    try testing.expectEqual(level2.current_node.?, n4);
    try testing.expect(n4.prev_node != null);
    try testing.expectEqual(n3, n4.prev_node.?);

    var restore_level = level2.endLevel(allocator);
    try testing.expectEqual(restore_level, level);
    try testing.expectEqual(level.current_node, n4);

    try testing.expect(n2.children != null);
    try testing.expect(n2.children.?.len == 2);
    try testing.expectEqual(n2.children.?[0], n3);
    try testing.expectEqual(n2.children.?[1], n4);
}