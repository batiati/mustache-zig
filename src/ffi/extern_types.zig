/// Must be kept in sync with src/ffi/mustache.h
const std = @import("std");
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;

pub const UserDataHandle = ?*const anyopaque;
pub const WriterHandle = *anyopaque;
pub const LambdaHandle = *anyopaque;
pub const TemplateHandle = *anyopaque;

pub const Status = enum(c_int) {
    SUCCESS = 0,
    INVALID_ARGUMENT = 1,
    PARSE_ERROR = 2,
    INTERPOLATION_ERROR = 3,
    OUT_OF_MEMORY = 4,
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
    next: ?*const PathPart,
};

pub const Path = extern struct {
    root: ?*const PathPart,
    index: u32,
    has_index: bool,
};

pub const WriteFn = *const fn (writer_handle: ?WriterHandle, value: ?[*]const u8, len: u32) callconv(.C) Status;

pub const UserData = extern struct {
    handle: UserDataHandle,
    get: ?*const fn (user_data_handle: UserDataHandle, path: *const Path, out_value: *UserData) callconv(.C) PathResolution,
    capacityHint: ?*const fn (user_data_handle: UserDataHandle, path: *const Path, out_value: *u32) callconv(.C) PathResolution,
    interpolate: ?*const fn (writer_handle: WriterHandle, write_fn: WriteFn, user_data_handle: UserDataHandle, path: *const Path) callconv(.C) PathResolution,
    expandLambda: ?*const fn (lambda_handle: LambdaHandle, user_data_handle: UserDataHandle, path: *const Path) callconv(.C) PathResolution,
};

pub extern fn mustache_create_template(template_text: ?[*]const u8, template_len: u32, out_template_handle: *TemplateHandle) callconv(.C) Status;

pub extern fn mustache_free_template(template_handle: ?TemplateHandle) callconv(.C) Status;

pub extern fn mustache_render(template_handle: ?TemplateHandle, user_data: UserData, out_buffer: *[*]const u8, out_buffer_len: *u32) callconv(.C) Status;

pub extern fn mustache_free_buffer(buffer: ?[*]const u8, buffer_len: u32) callconv(.C) Status;
