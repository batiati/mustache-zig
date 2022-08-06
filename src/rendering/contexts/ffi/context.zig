const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const testing = std.testing;

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

const extern_types = @import("extern_types.zig");

/// FFI context can resolve paths from foreign elements
/// This struct implements the expected context interface using static dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn Context(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const PATH_MAX_PARTS = 128;

    const RenderEngine = rendering.RenderEngine(.ffi, Writer, PartialsMap, options);
    const DataRender = RenderEngine.DataRender;

    return struct {
        const Self = @This();

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: Self,
        };

        pub const Iterator = ContextIterator(Self);

        user_data: extern_types.ffi_UserData = undefined,

        pub fn context(user_data: extern_types.ffi_UserData) Self {
            return .{
                .user_data = user_data,
            };
        }

        pub fn get(self: Self, path: Element.Path, index: ?usize) PathResolution(Self) {
            var ffi_parts: [PATH_MAX_PARTS]extern_types.ffi_ElementPathPart = undefined;
            var ffi_path = extern_types.ffi_ElementPath.get(&ffi_parts, path, index);

            var out_value: *anyopaque = undefined;
            var ret = self.user_data.callbacks.get(self.user_data.value, ffi_path, &out_value);

            return switch (ret) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field, .lambda => blk: {
                    var ctx = RenderEngine.getContext(
                        extern_types.ffi_UserData{
                            .value = out_value,
                            .ffi = self.user_data.callbacks,
                        },
                    );

                    break :blk if (ret == .field) .{ .field = ctx } else .{ .lambda = ctx };
                },
            };
        }

        pub fn capacityHint(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            var ffi_parts: [PATH_MAX_PARTS]extern_types.ffi_ElementPathPart = undefined;
            var ffi_path = extern_types.ffi_ElementPath.get(&ffi_parts, path, null);

            _ = data_render;
            var capacity: u32 = undefined;
            var ret = self.user_data.callbacks.capacityHint(self.user_data.value, ffi_path, &capacity);

            return switch (ret) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => .{ .field = capacity },
                .lambda => .{ .lambda = capacity },
            };
        }

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var ffi_parts: [PATH_MAX_PARTS]extern_types.ffi_ElementPathPart = undefined;
            var ffi_path = extern_types.ffi_ElementPath.get(&ffi_parts, path, null);

            _ = escape;
            var ret = self.user_data.callbacks.interpolate(data_render, self.user_data.value, ffi_path);

            return if (ret.has_error)
                @errSetCast(Allocator.Error || Writer.Error, ret.err)
            else switch (ret.ret) {
                .not_found_in_context => PathResolution(void).not_found_in_context,
                .chain_broken => PathResolution(void).chain_broken,
                .iterator_consumed => PathResolution(void).iterator_consumed,
                .field => PathResolution(void).field,
                .lambda => PathResolution(void).lambda,
            };
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

            // not supported yet
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
    };
}
