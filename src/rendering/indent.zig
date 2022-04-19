const std = @import("std");

const assert = std.debug.assert;
const testing = std.testing;

pub const IndentationQueue = struct {
    const Self = @This();

    pub const Node = struct {
        next: ?*@This() = null,
        indentation: []const u8,
    };

    list: ?struct {
        head: *Node,
        tail: *Node,
    } = null,
    has_pending: bool = false,

    pub fn indent(self: *Self, node: *Node) void {
        if (self.list) |list| {
            list.tail.next = node;
            self.list = .{
                .head = list.head,
                .tail = node,
            };
        } else {
            self.list = .{
                .head = node,
                .tail = node,
            };
        }
    }

    pub fn unindent(self: *Self) void {
        if (self.list) |list| {
            if (list.head == list.tail) {
                self.list = null;
            } else {
                var current_level: *Node = list.head;
                while (true) {
                    var next_level = current_level.next orelse break;
                    defer current_level = next_level;

                    if (next_level == list.tail) {
                        current_level.next = null;
                        self.list = .{
                            .head = list.head,
                            .tail = current_level,
                        };

                        return;
                    }
                }

                unreachable;
            }

            if (list.tail.next == null) {
                self.list = null;
            } else {
                list.tail.next = null;
            }
        }
    }

    pub fn write(self: Self, writer: anytype) !usize {
        var written_bytes: usize = 0;
        if (self.list) |list| {
            var node: ?*const Node = list.head;
            while (node) |level| : (node = level.next) {
                try writer.writeAll(level.indentation);
                written_bytes += level.indentation.len;
            }
        }

        return written_bytes;
    }
};

test "Indent/Unindent" {
    var queue = IndentationQueue{};
    try testing.expect(queue.list == null);

    var node_1 = IndentationQueue.Node{
        .indentation = "",
    };
    queue.indent(&node_1);

    try testing.expect(queue.list != null);
    try testing.expect(queue.list.?.head == queue.list.?.tail);
    try testing.expect(queue.list.?.head == &node_1);
    try testing.expect(queue.list.?.tail == &node_1);

    var node_2 = IndentationQueue.Node{
        .indentation = "",
    };
    queue.indent(&node_2);

    try testing.expect(queue.list != null);
    try testing.expect(queue.list.?.head != queue.list.?.tail);
    try testing.expect(queue.list.?.head == &node_1);
    try testing.expect(queue.list.?.tail == &node_2);
    try testing.expect(node_1.next == &node_2);

    var node_3 = IndentationQueue.Node{
        .indentation = "",
    };
    queue.indent(&node_3);

    try testing.expect(queue.list != null);
    try testing.expect(queue.list.?.head != queue.list.?.tail);
    try testing.expect(queue.list.?.head == &node_1);
    try testing.expect(queue.list.?.tail == &node_3);
    try testing.expect(node_1.next == &node_2);
    try testing.expect(node_2.next == &node_3);

    queue.unindent();
    try testing.expect(queue.list != null);
    try testing.expect(queue.list.?.head != queue.list.?.tail);
    try testing.expect(queue.list.?.head == &node_1);
    try testing.expect(queue.list.?.tail == &node_2);
    try testing.expect(node_2.next == null);
    try testing.expect(node_1.next == &node_2);

    queue.unindent();
    try testing.expect(queue.list != null);
    try testing.expect(queue.list.?.head == queue.list.?.tail);
    try testing.expect(queue.list.?.head == &node_1);
    try testing.expect(queue.list.?.tail == &node_1);
    try testing.expect(node_1.next == null);

    queue.unindent();
    try testing.expect(queue.list == null);
}
