const std = @import("std");
const Allocator = std.mem.Allocator;

const mustache = @import("mustache");

const extern_types = @import("extern_types.zig");
const Writer = @import("Writer.zig");

//pub export fn mustache_parse_template(template_text: [*]const u8, template_len: u32, out_template_handle: *TemplateHandle) callconv(.C) Status;

//pub export fn mustache_render(template_handle: TemplateHandle, user_data: UserData) callconv(.C) Status;

pub export fn mustache_interpolate(writer_handle: extern_types.WriterHandle, value: [*]const u8, len: u32) callconv(.C) extern_types.Status {
    var writer = @ptrCast(*Writer, @alignCast(@alignOf(Writer), writer_handle));
    writer.write(value[0..len]) catch {
        return .INTERPOLATION_ERROR;
    };

    return .SUCCESS;
}
