const std = @import("std");
const Allocator = std.mem.Allocator;

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

const Self = @This();

parent: ?*Self,
delimiters: Delimiters,
list: std.ArrayList(Node),

pub fn init(allocator: Allocator, parent: ?*Self, delimiters: Delimiters) !*Self {
    var self = try allocator.create(Self);
    self.* = .{
        .parent = parent,
        .delimiters = delimiters,
        .list = std.ArrayList(Node).init(allocator),
    };

    return self;
}

pub fn trimStandAloneTag(self: *const Self, part_type: PartType, part: *TextPart) void {

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
        if (self.peek()) |level_part| {
            if (level_part.part_type.canBeStandAlone()) {
                part.trimStandAlone(.Left);
            }
        }
    } else if (part_type.canBeStandAlone()) {
        if (self.peek()) |level_part| {
            if (level_part.part_type == .StaticText) {
                level_part.text_part.trimStandAlone(.Right);
            }
        }
    }
}

pub fn peek(self: *const Self) ?*Node {
    var level: ?*const Self = self;

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

pub fn endLevel(self: *Self) []const Node {
    const allocator = self.list.allocator;

    allocator.destroy(self);
    return self.list.toOwnedSlice();
}
