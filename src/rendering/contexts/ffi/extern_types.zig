/// Must be kept in sync with src/ffi/mustache.h
const std = @import("std");
const assert = std.debug.assert;

const mustache = @import("../../../mustache.zig");
const Element = mustache.Element;

pub const UserDataHandle = *const anyopaque;
pub const WriterHandle = *const anyopaque;
pub const LambdaHandle = *const anyopaque;
pub const TemplateHandle = *const anyopaque;

pub const Status = enum(c_int) {
    SUCCESS = 0,
    INVALID_TEMPLATE = 1,
    INVALID_USER_DATA = 2,
    PARSE_ERROR = 3,
};

pub const PathResolution = enum(c_int) {
    NOT_FOUND_IN_CONTEXT = 0,
    CHAIN_BROKEN = 1,
    ITERATOR_CONSUMED = 2,
    LAMBDA = 3,
    FIELD = 4,
};

pub const PathResolutionOrError = extern struct {
    result: PathResolution,
    has_error: bool,
    error_code: u64,
};

pub const PathPart = extern struct {
    value: [*]const u8,
    size: u32,
};

pub const Path = extern struct {
    path: [*]PathPart,
    path_size: u32,
    index: u32,
    has_index: bool,

    pub fn get(buffer: []PathPart, path: Element.Path, index: ?usize) Path {
        assert(buffer.len >= path.len);

        for (path) |part, i| {
            buffer[i] = .{
                .value = part.ptr,
                .size = @intCast(u32, part.len),
            };
        }

        return .{
            .path = buffer.ptr,
            .path_size = @intCast(u32, path.len),
            .index = @intCast(u32, index orelse 0),
            .has_index = index != null,
        };
    }
};

pub const Callbacks = extern struct {
    get: fn (user_data_handle: UserDataHandle, path: Path, out_value: *UserData) callconv(.C) PathResolution,
    capacityHint: fn (user_data_handle: UserDataHandle, path: Path, out_value: *u32) callconv(.C) PathResolution,
    interpolate: fn (writer_handle: WriterHandle, user_data_handle: UserDataHandle, path: Path) callconv(.C) PathResolutionOrError,
    expandLambda: fn (lambda_handle: LambdaHandle, user_data_handle: UserDataHandle, path: Path) callconv(.C) PathResolutionOrError,
};

pub const UserData = extern struct {
    handle: UserDataHandle,
    callbacks: Callbacks,
};

pub extern fn mustache_parse_template(template_text: [*]const u8, template_len: u32, out_template_handle: *TemplateHandle) callconv(.C) Status;

pub extern fn mustache_render(template_handle: TemplateHandle, user_data: UserData) callconv(.C) Status;
