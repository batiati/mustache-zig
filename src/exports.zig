const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const mustache = @import("mustache.zig");

const extern_types = @import("ffi/extern_types.zig");

pub export fn mustache_create_template(template_text: ?[*]const u8, template_len: u32, out_template_handle: *extern_types.TemplateHandle) callconv(.C) extern_types.Status {
    if (template_text) |buffer| {
        var allocator = if (comptime builtin.link_libc) std.heap.c_allocator else testing.allocator;
        const result = mustache.parseText(allocator, buffer[0..template_len], .{}, .{ .copy_strings = true }) catch |err| switch (err) {
            error.OutOfMemory => return .OUT_OF_MEMORY,
        };

        switch (result) {
            .success => |template| {
                var ptr = allocator.create(mustache.Template) catch return .OUT_OF_MEMORY;
                ptr.* = template;
                out_template_handle.* = ptr;
                return .SUCCESS;
            },
            .parse_error => return .PARSE_ERROR,
        }
    } else {
        return .INVALID_ARGUMENT;
    }
}

pub export fn mustache_free_template(template_handle: ?extern_types.TemplateHandle) callconv(.C) extern_types.Status {
    if (template_handle) |handle| {
        var template = @ptrCast(*mustache.Template, @alignCast(@alignOf(mustache.Template), handle));

        var allocator = if (comptime builtin.link_libc) std.heap.c_allocator else testing.allocator;
        template.deinit(allocator);
        allocator.destroy(template);

        return .SUCCESS;
    } else {
        return .INVALID_ARGUMENT;
    }
}

pub export fn mustache_render(template_handle: ?extern_types.TemplateHandle, user_data: extern_types.UserData, out_buffer: *[*]const u8, out_buffer_len: *u32) callconv(.C) extern_types.Status {
    if (template_handle) |handle| {
        var template = @ptrCast(*mustache.Template, @alignCast(@alignOf(mustache.Template), handle));

        var allocator = if (comptime builtin.link_libc) std.heap.c_allocator else testing.allocator;
        const result = mustache.allocRenderZ(allocator, template.*, user_data) catch |err| switch (err) {
            error.OutOfMemory => return .OUT_OF_MEMORY,
        };

        out_buffer.* = result.ptr;
        out_buffer_len.* = @intCast(u32, result.len);

        return .SUCCESS;
    } else {
        return .INVALID_ARGUMENT;
    }
}

pub export fn mustache_free_buffer(buffer: ?[*]const u8, buffer_len: u32) callconv(.C) extern_types.Status {
    if (buffer) |ptr| {
        var allocator = if (comptime builtin.link_libc) std.heap.c_allocator else testing.allocator;
        allocator.free(ptr[0..buffer_len]);

        return .SUCCESS;
    } else {
        return .INVALID_ARGUMENT;
    }
}
