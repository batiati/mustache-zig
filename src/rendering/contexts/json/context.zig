const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const testing = std.testing;

const json = std.json;

const mustache = @import("../../../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;
const Element = mustache.Element;

const rendering = @import("../../rendering.zig");
const ContextType = rendering.ContextType;

const context = @import("../../context.zig");
const PathResolution = context.PathResolution;
const Escape = context.Escape;
const ContextIterator = context.ContextIterator;

/// Json context can resolve paths for std.json.Value objects
/// This struct implements the expected context interface using static dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn Context(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(.json, Writer, PartialsMap, options);
    const DataRender = RenderEngine.DataRender;
    const Depth = enum { Root, Leaf };

    return struct {
        const Self = @This();

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: Self,
        };

        pub const Iterator = ContextIterator(Self);

        ctx: json.Value = undefined,

        pub fn context(json_value: json.Value) Self {
            return .{
                .ctx = json_value,
            };
        }

        pub fn get(self: Self, path: Element.Path, index: ?usize) PathResolution(Self) {
            const value = getJsonValue(.Root, self.ctx, path, index);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| .{ .field = RenderEngine.getContext(content) },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        pub fn capacityHint(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            const value = getJsonValue(.Root, self.ctx, path, null);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| switch (content) {
                    .Bool => |boolean| return .{ .field = data_render.valueCapacityHint(boolean) },
                    .Integer => |integer| return .{ .field = data_render.valueCapacityHint(integer) },
                    .Float => |float| return .{ .field = data_render.valueCapacityHint(float) },
                    .NumberString => |number_string| return .{ .field = data_render.valueCapacityHint(number_string) },
                    .String => |string| return .{ .field = data_render.valueCapacityHint(string) },
                    .Array => |array| return .{ .field = data_render.valueCapacityHint(array.items) },
                    else => return .{ .field = 0 },
                },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const value = getJsonValue(.Root, self.ctx, path, null);

            switch (value) {
                .not_found_in_context => return .not_found_in_context,
                .chain_broken => return .chain_broken,
                .iterator_consumed => return .iterator_consumed,
                .field => |content| switch (content) {
                    .Bool => |boolean| try data_render.write(boolean, escape),
                    .Integer => |integer| try data_render.write(integer, escape),
                    .Float => |float| try data_render.write(float, escape),
                    .NumberString => |number_string| try data_render.write(number_string, escape),
                    .String => |string| try data_render.write(string, escape),
                    .Array => |array| try data_render.write(array.items, escape),
                    else => {},
                },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            }

            return .field;
        }

        pub inline fn expandLambda(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            _ = self;
            _ = data_render;
            _ = path;
            _ = inner_text;
            _ = escape;
            _ = delimiters;

            // Json objects cannot have declared lambdas
            return PathResolution(void).chain_broken;
        }

        pub fn iterator(self: *const Self, path: Element.Path) PathResolution(Iterator) {
            const result = self.get(path, 0);

            return switch (result) {
                .field => |item| .{
                    .field = Iterator.initSequence(self, path, item),
                },
                .iterator_consumed => .{
                    .field = Iterator.initEmpty(),
                },
                .lambda => |item| .{
                    .field = Iterator.initLambda(item),
                },
                .chain_broken => .chain_broken,
                .not_found_in_context => .not_found_in_context,
            };
        }

        fn getJsonValue(depth: Depth, value: json.Value, path: Element.Path, index: ?usize) PathResolution(json.Value) {
            if (path.len == 0) {
                if (index) |current_index| {
                    switch (value) {
                        .Array => |array| if (array.items.len > current_index) {
                            return .{ .field = array.items[current_index] };
                        },
                        .Bool => |boolean| if (boolean == true and current_index == 0) {
                            return .{ .field = value };
                        },
                        else => if (current_index == 0) {
                            return .{ .field = value };
                        },
                        .Null => {},
                    }

                    return .iterator_consumed;
                } else {
                    return .{ .field = value };
                }
            } else {
                switch (value) {
                    .Object => |obj| {
                        const key = path[0];

                        if (obj.get(key)) |next_value| {
                            return getJsonValue(.Leaf, next_value, path[1..], index);
                        }
                    },

                    else => {},
                }
            }

            return if (depth == .Root) .not_found_in_context else .chain_broken;
        }
    };
}
