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
const ContextSource = rendering.ContextSource;

const context = @import("../../context.zig");
const PathResolutionType = context.PathResolutionType;
const Escape = context.Escape;
const ContextIteratorType = context.ContextIteratorType;

/// Json context can resolve paths for std.json.Value objects
/// This struct implements the expected context interface using static dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn ContextType(
    comptime Writer: type,
    comptime PartialsMap: type,
    comptime TUserData: type,
    comptime options: RenderOptions,
) type {
    const RenderEngine = rendering.RenderEngineType(
        .json,
        Writer,
        PartialsMap,
        TUserData,
        options,
    );
    const DataRender = RenderEngine.DataRender;
    const Depth = enum { Root, Leaf };

    return struct {
        const Context = @This();

        pub const ContextIterator = ContextIteratorType(Context);

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: Context,
        };

        ctx: json.Value = undefined,

        pub fn ContextType(json_value: json.Value) Context {
            return .{
                .ctx = json_value,
            };
        }

        pub fn get(self: Context, path: Element.Path, index: ?usize) PathResolutionType(Context) {
            const value = getJsonValue(.Root, self.ctx, path, index);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| .{ .field = RenderEngine.getContextType(content) },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        pub fn capacityHint(
            self: Context,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolutionType(usize) {
            const value = getJsonValue(.Root, self.ctx, path, null);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| switch (content) {
                    .bool => |boolean| return .{ .field = data_render.valueCapacityHint(boolean) },
                    .integer => |integer| return .{ .field = data_render.valueCapacityHint(integer) },
                    .float => |float| return .{ .field = data_render.valueCapacityHint(float) },
                    .number_string => |number_string| return .{ .field = data_render.valueCapacityHint(number_string) },
                    .string => |string| return .{ .field = data_render.valueCapacityHint(string) },
                    .array => |array| return .{ .field = data_render.valueCapacityHint(array.items) },
                    else => return .{ .field = 0 },
                },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        pub inline fn interpolate(
            self: Context,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            const value = getJsonValue(.Root, self.ctx, path, null);

            switch (value) {
                .not_found_in_context => return .not_found_in_context,
                .chain_broken => return .chain_broken,
                .iterator_consumed => return .iterator_consumed,
                .field => |content| switch (content) {
                    .bool => |boolean| try data_render.write(boolean, escape),
                    .integer => |integer| try data_render.write(integer, escape),
                    .float => |float| try data_render.write(float, escape),
                    .number_string => |number_string| try data_render.write(number_string, escape),
                    .string => |string| try data_render.write(string, escape),
                    .array => |array| try data_render.write(array.items, escape),
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
            self: Context,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            _ = self;
            _ = data_render;
            _ = path;
            _ = inner_text;
            _ = escape;
            _ = delimiters;

            // Json objects cannot have declared lambdas
            return PathResolutionType(void).chain_broken;
        }

        pub fn iterator(
            self: *const Context,
            path: Element.Path,
        ) PathResolutionType(ContextIterator) {
            const result = self.get(path, 0);

            return switch (result) {
                .field => |item| .{
                    .field = ContextIterator.initSequence(self, path, item),
                },
                .iterator_consumed => .{
                    .field = ContextIterator.initEmpty(),
                },
                .lambda => |item| .{
                    .field = ContextIterator.initLambda(item),
                },
                .chain_broken => .chain_broken,
                .not_found_in_context => .not_found_in_context,
            };
        }

        fn getJsonValue(depth: Depth, value: json.Value, path: Element.Path, index: ?usize) PathResolutionType(json.Value) {
            if (path.len == 0) {
                if (index) |current_index| {
                    switch (value) {
                        .array => |array| if (array.items.len > current_index) {
                            return .{ .field = array.items[current_index] };
                        },
                        .bool => |boolean| if (boolean == true and current_index == 0) {
                            return .{ .field = value };
                        },
                        else => if (current_index == 0) {
                            return .{ .field = value };
                        },
                        .null => {},
                    }

                    return .iterator_consumed;
                } else {
                    return .{ .field = value };
                }
            } else {
                switch (value) {
                    .object => |obj| {
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
