const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;
const MustacheError = mustache.MustacheError;

const scanner = @import("scanner.zig");
const tokens = scanner.tokens;
const TextPart = scanner.TextPart;
const PartType = scanner.PartType;
const Mark = scanner.Mark;

pub const Node = struct {
    part_type: PartType,
    text_part: TextPart,
    children: ?[]const Node = null,
};

const Level = struct {
    parent: ?*Level,
    delimiters: Delimiters,
    list: std.ArrayListUnmanaged(Node) = .{},

    pub fn peek(self: *const Level) ?*Node {
        var level: ?*const Level = self;

        while (level) |current_level| {
            const items = current_level.list.items;
            if (items.len == 0) {
                level = current_level.parent;
            } else {
                return &items[items.len - 1];
            }
        }

        return null;
    }
};

const Self = @This();

arena: Allocator,
root: *Level,
current_level: *Level,

pub fn init(arena: Allocator, delimiters: Delimiters) !Self {
    var root = try arena.create(Level);
    root.* = .{
        .parent = null,
        .delimiters = delimiters,
    };

    return Self{
        .arena = arena,
        .root = root,
        .current_level = root,
    };
}

pub fn setCurrentDelimiters(self: *Self, delimiters: Delimiters) void {
    self.current_level.delimiters = delimiters;
}

pub fn getCurrentDelimiters(self: *Self) Delimiters {
    return self.current_level.delimiters;
}

pub fn nextLevel(self: *Self) !void {
    var current_level = self.current_level;
    var next_level = try self.arena.create(Level);

    next_level.* = .{
        .parent = current_level,
        .delimiters = current_level.delimiters,
    };

    self.current_level = next_level;
}

pub fn endLevel(self: *Self) !void {
    var current_level = self.current_level;
    var prev_level = current_level.parent orelse return MustacheError.UnexpectedCloseSection;
    var last_node = prev_level.peek() orelse return MustacheError.UnexpectedCloseSection;

    last_node.children = current_level.list.toOwnedSlice(self.arena);
    self.arena.destroy(current_level);

    self.current_level = prev_level;
}

pub fn endRoot(self: *Self) ![]Node {
    if (self.current_level != self.root) {
        return MustacheError.UnexpectedEof;
    }

    const nodes = self.root.list.toOwnedSlice(self.arena);
    self.arena.destroy(self.root);

    return nodes;
}

pub fn addNode(self: *Self, part_type: PartType, text_part: *const TextPart) !void {
    try self.current_level.list.append(
        self.arena,
        .{
            .part_type = part_type,
            .text_part = text_part.*,
        },
    );
}

pub fn trimStandAlone(self: *const Self, part_type: PartType, text_part: *TextPart) void {

    // Lines containing tags without any static text or interpolation
    // must be fully removed from the rendered result
    //
    // Examples:
    //
    // 1. TRIM LEFT
    //                                            ┌ any white space after that must be TRIMMED,
    //                                            ↓ including the line break
    // var template_text = \\{{! Comments block }}
    //                     \\Hello World
    //
    // 2. TRIM RIGHT
    //                            ┌ any white space before that must be trimmed,
    //                            ↓
    // var template_text = \\      {{! Comments block }}
    //                     \\Hello World
    //
    // 3. PRESERVE
    //                                     ┌ any white space and the line break after that must be PRESERVED,
    //                                     ↓
    // var template_text = \\      {{Name}}
    //                     \\      {{Address}}
    //                            ↑
    //                            └ any white space before that must be PRESERVED,

    if (part_type == .StaticText) {
        if (self.current_level.peek()) |level_part| {
            if (level_part.part_type.canBeStandAlone()) {
                text_part.trimStandAlone(.Left);
            }
        }
    } else if (part_type.canBeStandAlone()) {
        if (self.current_level.peek()) |level_part| {
            if (level_part.part_type == .StaticText) {
                level_part.text_part.trimStandAlone(.Right);
            }
        }
    }
}
