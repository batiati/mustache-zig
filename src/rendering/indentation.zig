const std = @import("std");

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Element = mustache.Element;

pub fn IndentationQueue(comptime options: RenderOptions) type {
    const Impl = struct {
        const Self = @This();

        pub const Indentation = struct {
            pub const LinePos = enum { Middle, Last };

            value: ?struct {
                first: *const Node,
                trim_last_line: bool = false,
            } = null,

            pub fn write(self: @This(), comptime line: LinePos, writer: anytype) !usize {
                var written_bytes: usize = 0;
                if (self.value) |value| {
                    var node: ?*const Node = value.first;
                    while (node) |level| {
                        if (line == .Last)
                            if (value.trim_last_line and level.next == null) break;

                        defer node = level.next;

                        try writer.writeAll(level.indentation);
                        written_bytes += level.indentation.len;
                    }
                }

                return written_bytes;
            }

            pub inline fn hasValue(self: @This()) bool {
                return self.value != null;
            }
        };

        pub const IteratorState = enum {
            None,
            Fetching,
            Consumed,
        };

        pub const Node = struct {
            next: ?*const @This() = null,
            indentation: []const u8,
            last_indented_element: *const Element,
            iterator_state: IteratorState = .None,
        };

        list: ?struct {
            head: *Node,
            tail: *Node,
            last_iterator_state: ?IteratorState = null,
        } = null,

        pub fn indent(self: Self, node: *Node) Self {
            if (self.list) |list| {
                list.tail.next = node;
                return .{
                    .list = .{
                        .head = list.head,
                        .tail = node,
                    },
                };
            } else {
                return .{ .list = .{
                    .head = node,
                    .tail = node,
                } };
            }
        }

        pub fn unindent(self: Self) void {
            if (self.list) |list| {
                list.tail.next = null;
            }
        }

        pub inline fn get(self: *const Self, element: *const Element) Indentation {
            if (self.list) |list| {
                const tail = list.tail;
                const trim_last_line = tail.last_indented_element == element and tail.iterator_state != .Fetching;

                return .{
                    .value = .{
                        .first = list.head,
                        .trim_last_line = trim_last_line,
                    },
                };
            } else {
                return .{
                    .value = null,
                };
            }
        }

        pub inline fn indentSection(self: *Self, has_next: bool) void {
            if (self.list) |*list| {
                assert(list.last_iterator_state == null);

                const tail = list.tail;
                list.last_iterator_state = tail.iterator_state;
                tail.iterator_state = if (has_next) .Fetching else .Consumed;
            }
        }

        pub inline fn unindentSection(self: *Self) void {
            if (self.list) |*list| {
                assert(list.last_iterator_state != null);

                const tail = list.tail;
                tail.iterator_state = list.last_iterator_state.?;
                list.last_iterator_state = null;
            }
        }
    };

    const Null = struct {
        const Self = @This();

        pub const Indentation = struct {
            pub inline fn hasValue(self: @This()) bool {
                _ = self;
                return false;
            }
        };
        pub inline fn get(self: Self, element: *const Element) Indentation {
            _ = self;
            _ = element;

            return Indentation{};
        }

        pub inline fn indentSection(self: Self, has_next: bool) void {
            _ = self;
            _ = has_next;
        }

        pub inline fn unindentSection(self: Self) void {
            _ = self;
        }
    };

    return if (options.preseve_line_breaks_and_indentation) Impl else Null;
}
