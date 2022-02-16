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

pub const LevelPart = struct {
    part_type: PartType,
    text_part: TextPart,
    nested_parts: ?[]const LevelPart = null,
};

const Self = @This();

parent: ?*Level,
delimiters: Delimiters,
list: std.ArrayList(LevelPart),

pub fn init(allocator: Allocator, parent: ?*Self, delimiters: Delimiters) !*Self {
    var self = try allocator.create(Self);
    self.* = .{
        .parent = parent,
        .delimiters = delimiters,
        .list = std.ArrayList(LevelPart).init(allocator),
    };

    return self;
}

pub fn trimStandAloneTag(self: *const Self, part_type: PartType, part: *TextPart) void {
    if (part_type == .StaticText) {
        if (self.peek()) |level_part| {
            if (level_part.part_type.canBeStandAlone()) {

                //{{! Comments block }}    <--- Trim Left this
                //  Hello                  <--- This static text
                part.trimStandAlone(.Left);
            }
        }
    } else if (part_type.canBeStandAlone()) {
        if (self.peek()) |level_part| {
            if (level_part.part_type == .StaticText) {

                //Trim Right this --->   {{#section}}
                level_part.text_part.trimStandAlone(.Right);
            }
        }
    }
}

fn peek(self: *const Self) ?*LevelPart {
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

pub fn endLevel(self: *Self) []const LevelPart {
    const allocator = self.list.allocator;

    allocator.destroy(self);
    return self.list.toOwnedSlice();
}
