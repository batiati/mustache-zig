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

pub const ffi_Callbacks = struct {
    get: fn (user_data: *const anyopaque, path: ffi_ElementPath, out_value: **anyopaque) callconv(.C) ffi_Ret,
    capacityHint: fn (user_data: *const anyopaque, path: ffi_ElementPath, out_value: *u32) callconv(.C) ffi_Ret,
    interpolate: fn (writer_handle: *const anyopaque, user_data: *anyopaque, path: ffi_ElementPath) callconv(.C) ffi_ErrRet,
    expandLambda: fn (lambda_handle: *const anyopaque, user_data: *anyopaque, path: ffi_ElementPath) callconv(.C) ffi_ErrRet,
};

pub const ffi_UserData = extern struct {
    value: *anyopaque,
    callbacks: *const ffi_Callbacks,
};

pub const ffi_Ret = enum(u8) {
    not_found_in_context = 0,
    chain_broken = 1,
    iterator_consumed = 2,
    lambda = 3,
    field = 4,
};

pub const ffi_ErrRet = extern struct {
    value: ffi_Ret,
    has_error: bool,
    err: usize,
};

pub const ffi_ElementPath = extern struct {
    path: [*c]const ffi_ElementPathPart,
    path_size: u32,
    index: u32,
    has_index: bool,

    pub fn get(buffer: []ffi_ElementPathPart, path: Element.Path, index: ?usize) ffi_ElementPath {
        assert(buffer.len >= path.len);

        for (path) |part, i| {
            buffer[i] = .{
                .value = part.ptr,
                .size = part.len,
            };
        }

        return ffi_ElementPath{
            .path = buffer.ptr,
            .path_size = path.len,
            .index = @intCast(u32, index orelse 0),
            .has_index = index != null,
        };
    }
};

pub const ffi_ElementPathPart = extern struct {
    value: [*c]const u8,
    size: usize,
};
