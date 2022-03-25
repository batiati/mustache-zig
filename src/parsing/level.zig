const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Options = mustache.Options;
const Delimiters = mustache.Delimiters;
const ParseError = mustache.ParseError;

const parsing = @import("parsing.zig");
const BlockType = parsing.BlockType;

const assert = std.debug.assert;
const testing = std.testing;

pub fn Level(comptime options: Options) type {
    const TextBlock = parsing.TextBlock(options);
    const Node = parsing.Node(options);

    const has_trimming = options.features.preseve_line_breaks_and_indentation;

    return struct {
        pub const EndLevel = struct {
            level: *Self,
            parent_node: *Node,
        };

        const Self = @This();

        const List = struct {
            items: ?struct {
                head: *Node,
                tail: *Node,
            } = null,

            fn add(self: *@This(), node: *Node) void {
                if (self.items) |*items| {
                    items.tail.link.next_sibling = node;
                    items.tail = node;
                } else {
                    self.items = .{
                        .head = node,
                        .tail = node,
                    };
                }
            }

            ///
            /// Return true if the last node could be removed (only when there are at least two nodes)
            pub fn removeLast(self: *@This()) bool {
                const lastButOne = struct {
                    fn action(current: *Node, tail: *Node) *Node {
                        const next_sibling = current.link.next_sibling orelse unreachable;
                        return if (next_sibling == tail) current else action(next_sibling, tail);
                    }
                }.action;

                if (self.items) |*items| {
                    if (items.head != items.tail) {
                        var node = lastButOne(items.head, items.tail);
                        node.link.next_sibling = null;
                        items.tail = node;

                        return true;
                    }
                }

                return false;
            }

            ///
            /// Clear the list returning the head node
            pub fn finish(self: *@This()) ?*Node {
                if (self.items) |items| {
                    defer self.items = null;
                    return items.head;
                } else {
                    return null;
                }
            }
        };

        parent: ?*Self,
        delimiters: Delimiters,
        current_node: ?*Node,

        list: List = .{},

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
                .link = .{
                    .prev = if (has_trimming) self.current_node else {},
                },
            };

            self.list.add(node);
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

        pub fn endLevel(self: *Self) ParseError!EndLevel {
            var prev_level = self.parent orelse return ParseError.UnexpectedCloseSection;
            var parent_node = prev_level.current_node orelse return ParseError.UnexpectedCloseSection;

            parent_node.link.child = self.list.finish();
            prev_level.current_node = self.current_node;

            return EndLevel{ .level = prev_level, .parent_node = parent_node };
        }

        test "Level" {
            var arena = ArenaAllocator.init(testing.allocator);
            defer arena.deinit();

            const allocator = arena.allocator();

            var level = try Self.init(allocator, .{});
            try testing.expect(level.current_node == null);

            try level.addNode(allocator, undefined, undefined);
            try testing.expect(level.current_node != null);
            var n1 = level.current_node;

            try testing.expect(n1 != null);
            try testing.expect(n1.?.link.prev == null);
            try testing.expect(n1.?.link.next_sibling == null);

            try level.addNode(allocator, undefined, undefined);
            try testing.expect(level.current_node != null);
            var n2 = level.current_node.?;
            try testing.expect(n2.link.prev != null);
            try testing.expectEqual(n1, n2.link.prev.?);
            try testing.expect(n2.link.next_sibling == null);
            try testing.expect(n1.?.link.next_sibling != null);
            try testing.expectEqual(n2, n1.?.link.next_sibling.?);

            var level2 = try level.nextLevel(allocator);
            try testing.expect(level2.current_node != null);
            try testing.expectEqual(level2.current_node.?, n2);

            try level2.addNode(allocator, undefined, undefined);
            try testing.expect(level2.current_node != null);
            var n3 = level2.current_node.?;
            try testing.expect(n3.link.prev != null);
            try testing.expectEqual(n2, n3.link.prev.?);
            try testing.expect(n3.link.next_sibling == null);
            try testing.expect(n2.link.next_sibling == null);

            try level2.addNode(allocator, undefined, undefined);
            try testing.expect(level2.current_node != null);
            var n4 = level2.current_node.?;
            try testing.expectEqual(level2.current_node.?, n4);
            try testing.expect(n4.link.prev != null);
            try testing.expectEqual(n3, n4.link.prev.?);
            try testing.expect(n4.link.next_sibling == null);
            try testing.expect(n3.link.next_sibling != null);
            try testing.expectEqual(n4, n3.link.next_sibling.?);

            var siblings_l1 = n1.?.siblings();
            try testing.expectEqual(siblings_l1.len(), 2);
            try testing.expectEqual(siblings_l1.next().?, n1.?);
            try testing.expectEqual(siblings_l1.next().?, n2);
            try testing.expectEqual(siblings_l1.next(), null);

            var siblings_l2 = n3.siblings();
            try testing.expectEqual(siblings_l2.len(), 2);
            try testing.expectEqual(siblings_l2.next().?, n3);
            try testing.expectEqual(siblings_l2.next().?, n4);
            try testing.expectEqual(siblings_l2.next(), null);

            var restore_level = try level2.endLevel();
            try testing.expectEqual(restore_level.level, level);
            try testing.expectEqual(level.current_node, n4);

            try testing.expect(n2.link.child != null);
            try testing.expectEqual(n2.link.child.?, n3);

            var children = n2.children();
            try testing.expect(children.len() == 2);
            try testing.expectEqual(children.next(), n3);
            try testing.expectEqual(children.next(), n4);
            try testing.expectEqual(children.next(), null);
        }

        test "List" {
            var list = List{};
            try testing.expect(list.items == null);
            try testing.expectEqual(false, list.removeLast());

            var n1: Node = .{
                .block_type = undefined,
                .text_block = undefined,
                .inner_text = undefined,
            };

            list.add(&n1);
            try testing.expect(list.items != null);
            try testing.expectEqual(&n1, list.items.?.head);
            try testing.expectEqual(&n1, list.items.?.tail);
            try testing.expectEqual(false, list.removeLast());

            var n2: Node = .{
                .block_type = undefined,
                .text_block = undefined,
                .inner_text = undefined,
            };

            list.add(&n2);
            try testing.expect(list.items != null);
            try testing.expectEqual(&n1, list.items.?.head);
            try testing.expectEqual(&n2, list.items.?.tail);
            try testing.expect(list.items.?.head.link.next_sibling != null);
            try testing.expectEqual(&n2, list.items.?.head.link.next_sibling.?);

            var n3: Node = .{
                .block_type = undefined,
                .text_block = undefined,
                .inner_text = undefined,
            };

            list.add(&n3);
            try testing.expect(list.items != null);
            try testing.expectEqual(&n1, list.items.?.head);
            try testing.expectEqual(&n3, list.items.?.tail);
            try testing.expect(list.items.?.head.link.next_sibling != null);
            try testing.expectEqual(&n2, list.items.?.head.link.next_sibling.?);
            try testing.expect(list.items.?.head.link.next_sibling.?.link.next_sibling != null);
            try testing.expectEqual(&n3, list.items.?.head.link.next_sibling.?.link.next_sibling.?);

            try testing.expectEqual(true, list.removeLast());
            try testing.expectEqual(&n1, list.items.?.head);
            try testing.expectEqual(&n2, list.items.?.tail);

            const head = list.finish();
            try testing.expect(head != null);
            try testing.expect(list.items == null);
            try testing.expectEqual(&n1, head.?);
        }
    };
}

test {

    // Tests for both source modes
    _ = Level(.{ .source = .{ .String = .{} }, .output = .Parse });
    _ = Level(.{ .source = .{ .Stream = .{} }, .output = .Parse });
}
