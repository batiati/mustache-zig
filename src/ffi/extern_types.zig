/// Must be kept in sync with src/ffi/mustache.h
const std = @import("std");
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;

pub const UserDataHandle = *const anyopaque;
pub const WriterHandle = *anyopaque;
pub const LambdaHandle = *anyopaque;
pub const TemplateHandle = *const anyopaque;

pub const Status = enum(c_int) {
    SUCCESS = 0,
    INVALID_TEMPLATE = 1,
    INVALID_USER_DATA = 2,
    INVALID_WRITER = 3,
    PARSE_ERROR = 4,
    INTERPOLATION_ERROR = 5,
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
    error_code: c_int,
};

pub const PathPart = extern struct {
    value: [*]const u8,
    size: u32,
};

pub const Path = extern struct {
    path: [*]const PathPart,
    path_size: u32,
    index: u32,
    has_index: bool,
};

pub const Callbacks = extern struct {
    get: fn (user_data_handle: UserDataHandle, path: *const Path, out_value: *UserData) callconv(.C) PathResolution,
    capacityHint: fn (user_data_handle: UserDataHandle, path: *const Path, out_value: *u32) callconv(.C) PathResolution,
    interpolate: fn (writer_handle: WriterHandle, user_data_handle: UserDataHandle, path: *const Path) callconv(.C) PathResolutionOrError,
    expandLambda: fn (lambda_handle: LambdaHandle, user_data_handle: UserDataHandle, path: *const Path) callconv(.C) PathResolutionOrError,
};

pub const UserData = extern struct {
    handle: UserDataHandle,
    callbacks: Callbacks,
};

pub extern fn mustache_parse_template(template_text: [*]const u8, template_len: u32, out_template_handle: *TemplateHandle) callconv(.C) Status;

pub extern fn mustache_render(template_handle: TemplateHandle, user_data: UserData) callconv(.C) Status;

pub extern fn mustache_interpolate(writer_handle: WriterHandle, value: [*]const u8, len: u32) callconv(.C) Status;
