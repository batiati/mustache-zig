const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../../../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;
const Element = mustache.Element;

const rendering = @import("../../rendering.zig");
const map = @import("../../partials_map.zig");
const ContextType = rendering.ContextType;

const context = @import("../../context.zig");
const PathResolution = context.PathResolution;
const Escape = context.Escape;
const ContextIterator = context.ContextIterator;

const ffi_exports = @import("../../../exports.zig");
const extern_types = @import("../../../ffi/extern_types.zig");

/// FFI context can resolve paths from foreign elements
/// This struct implements the expected context interface using static dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn Context(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const PATH_MAX_PARTS = 128;

    const RenderEngine = rendering.RenderEngine(.ffi, Writer, PartialsMap, options);
    const DataRender = RenderEngine.DataRender;

    return struct {
        const Self = @This();

        /// Implements a Writer exposing a function pointer to be called from the FFI side
        pub const FfiWriter = struct {
            data_render: *DataRender,
            escape: Escape,

            fn write(ctx: ?*anyopaque, value: ?[*]const u8, len: u32) callconv(.C) extern_types.Status {
                if (ctx) |handle| {
                    if (value) |buffer| {
                        var self = @ptrCast(*@This(), @alignCast(@alignOf(@This()), handle));
                        self.data_render.write(buffer[0..len], self.escape) catch {
                            return .INTERPOLATION_ERROR;
                        };

                        return .SUCCESS;
                    }
                }

                return .INVALID_ARGUMENT;
            }
        };

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: Self,
        };

        pub const Iterator = ContextIterator(Self);

        user_data: extern_types.UserData = undefined,

        pub fn context(user_data: extern_types.UserData) Self {
            return .{
                .user_data = user_data,
            };
        }

        pub fn get(self: Self, path: Element.Path, index: ?usize) PathResolution(Self) {
            if (self.user_data.get) |callback| {
                var ffi_buffer: [PATH_MAX_PARTS]extern_types.PathPart = undefined;
                var ffi_path: extern_types.Path = undefined;
                convertPath(&ffi_path, &ffi_buffer, path, index);

                var out_value: extern_types.UserData = undefined;
                var ret = callback(self.user_data.handle, &ffi_path, &out_value);

                return switch (ret) {
                    .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                    .CHAIN_BROKEN => .chain_broken,
                    .ITERATOR_CONSUMED => .iterator_consumed,
                    .FIELD => .{ .field = RenderEngine.getContext(out_value) },
                    .LAMBDA => .{ .lambda = RenderEngine.getContext(out_value) },
                };
            } else {
                return .chain_broken;
            }
        }

        pub fn capacityHint(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            if (self.user_data.capacityHint) |callback| {
                var ffi_buffer: [PATH_MAX_PARTS]extern_types.PathPart = undefined;
                var ffi_path: extern_types.Path = undefined;
                convertPath(&ffi_path, &ffi_buffer, path, null);

                _ = data_render;
                var capacity: u32 = undefined;
                var ret = callback(self.user_data.handle, &ffi_path, &capacity);

                return switch (ret) {
                    .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                    .CHAIN_BROKEN => .chain_broken,
                    .ITERATOR_CONSUMED => .iterator_consumed,
                    .FIELD => .{ .field = capacity },
                    .LAMBDA => .{ .lambda = capacity },
                };
            } else {
                return .chain_broken;
            }
        }

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            if (self.user_data.interpolate) |callback| {
                var ffi_buffer: [PATH_MAX_PARTS]extern_types.PathPart = undefined;
                var ffi_path: extern_types.Path = undefined;
                convertPath(&ffi_path, &ffi_buffer, path, null);

                var writer = FfiWriter{
                    .data_render = data_render,
                    .escape = escape,
                };

                var ret = callback(&writer, FfiWriter.write, self.user_data.handle, &ffi_path);

                return switch (ret) {
                    .NOT_FOUND_IN_CONTEXT => PathResolution(void).not_found_in_context,
                    .CHAIN_BROKEN => PathResolution(void).chain_broken,
                    .ITERATOR_CONSUMED => PathResolution(void).iterator_consumed,
                    .FIELD => PathResolution(void).field,
                    .LAMBDA => PathResolution(void).lambda,
                };
            } else {
                return PathResolution(void).chain_broken;
            }
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

pub fn convertPath(out_path: *extern_types.Path, buffer: []extern_types.PathPart, path: Element.Path, index: ?usize) void {
    assert(buffer.len >= path.len);

    for (path) |part, i| {
        buffer[i] = .{
            .value = part.ptr,
            .size = @intCast(u32, part.len),
        };
    }

    out_path.* = .{
        .path = buffer.ptr,
        .path_size = @intCast(u32, path.len),
        .index = @intCast(u32, index orelse 0),
        .has_index = index != null,
    };
}

test {
    _ = context_tests;
}

const context_tests = struct {
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyPartialsMap = map.PartialsMap(void, dummy_options);
    const DummyWriter = std.ArrayList(u8).Writer;
    const DummyRenderEngine = rendering.RenderEngine(.ffi, DummyWriter, DummyPartialsMap, dummy_options);

    const parsing = @import("../../../parsing/parser.zig");
    const DummyParser = parsing.Parser(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
    const dummy_map = DummyPartialsMap.init({});

    fn expectPath(allocator: Allocator, path: []const u8) !Element.Path {
        var parser = try DummyParser.init(allocator, "", .{});
        defer parser.deinit();

        return try parser.parsePath(path);
    }

    fn interpolateCtx(writer: anytype, ctx: DummyRenderEngine.Context, identifier: []const u8, escape: Escape) anyerror!void {
        var stack = DummyRenderEngine.ContextStack{
            .parent = null,
            .ctx = ctx,
        };

        var data_render = DummyRenderEngine.DataRender{
            .stack = &stack,
            .out_writer = .{ .writer = writer },
            .partials_map = undefined,
            .indentation_queue = undefined,
            .template_options = {},
        };

        var path = try expectPath(testing.allocator, identifier);
        defer Element.destroyPath(testing.allocator, false, path);

        switch (try ctx.interpolate(&data_render, path, escape)) {
            .lambda => {
                _ = try ctx.expandLambda(&data_render, path, "", escape, .{});
            },
            else => {},
        }
    }

    const Person = struct {
        const Self = @This();

        id: u32,
        name: []const u8,

        pub fn get(user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path, out_value: *extern_types.UserData) callconv(.C) extern_types.PathResolution {
            if (path.path_size != 1) return .NOT_FOUND_IN_CONTEXT;
            var path_part = path.path[0];
            var path_value = path_part.value[0..path_part.size];

            var person = getSelf(user_data_handle);
            if (std.mem.eql(u8, path_value, "id")) {
                out_value.* = Person.getUserData(&person.id);
                return .FIELD;
            } else if (std.mem.eql(u8, path_value, "name")) {
                out_value.* = Person.getUserData(person.name.ptr);
                return .FIELD;
            }

            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn capacityHint(user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path, out_value: *u32) callconv(.C) extern_types.PathResolution {
            if (path.path_size == 1) {
                var path_part = path.path[0];
                var path_value = path_part.value[0..path_part.size];

                var person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    out_value.* = @intCast(u32, std.fmt.count("{}", .{person.id}));
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    out_value.* = @intCast(u32, person.name.len);
                    return .FIELD;
                }
            }
            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn interpolate(writer_handle: extern_types.WriterHandle, writer_fn: extern_types.WriteFn, user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path) callconv(.C) extern_types.PathResolution {
            if (path.path_size == 1) {
                var path_part = path.path[0];
                var path_value = path_part.value[0..path_part.size];

                // Using the FFI external function to interpolate,
                // Just like a foreign language would do.

                var person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    var buffer: [64]u8 = undefined;
                    var len = std.fmt.formatIntBuf(&buffer, person.id, 10, .lower, .{});

                    var ret = writer_fn(writer_handle, &buffer, @intCast(u32, len));
                    if (ret != .SUCCESS) return .CHAIN_BROKEN;

                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    var ret = writer_fn(writer_handle, person.name.ptr, @intCast(u32, person.name.len));
                    if (ret != .SUCCESS) return .CHAIN_BROKEN;

                    return .FIELD;
                }
            }

            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn expandLambda(lambda_handle: extern_types.LambdaHandle, user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path) callconv(.C) extern_types.PathResolution {
            _ = lambda_handle;
            _ = user_data_handle;
            _ = path;

            return .NOT_FOUND_IN_CONTEXT;
        }

        fn getSelf(user_data_handle: extern_types.UserDataHandle) *const Self {
            return @ptrCast(*const Self, @alignCast(@alignOf(Self), user_data_handle));
        }

        pub fn getUserData(handle: *const anyopaque) extern_types.UserData {
            return .{
                .handle = handle,
                .get = get,
                .capacityHint = capacityHint,
                .interpolate = interpolate,
                .expandLambda = expandLambda,
            };
        }
    };

    test "FFI path" {

        // Asserts the correct representation of a FFI Path structure

        const allocator = testing.allocator;
        const path = try expectPath(allocator, "abc.de.f");
        defer Element.destroyPath(allocator, false, path);

        var ffi_buffer: [3]extern_types.PathPart = undefined;
        var ffi_path: extern_types.Path = undefined;
        convertPath(&ffi_path, &ffi_buffer, path, 0);

        try testing.expect(ffi_path.has_index == true);
        try testing.expect(ffi_path.index == 0);

        try testing.expect(ffi_path.path_size == 3);

        try testing.expect(ffi_path.path[0].size == 3);
        try testing.expectEqualStrings(ffi_path.path[0].value[0..3], "abc");

        try testing.expect(ffi_path.path[1].size == 2);
        try testing.expectEqualStrings(ffi_path.path[1].value[0..2], "de");

        try testing.expect(ffi_path.path[2].size == 1);
        try testing.expectEqualStrings(ffi_path.path[2].value[0..1], "f");
    }

    test "FFI context get" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContext(user_data);

        var id_ctx = id_ctx: {
            const path = try expectPath(allocator, "id");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path, null)) {
                .field => |found| break :id_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer
        try testing.expectEqual(@ptrToInt(&person.id), @ptrToInt(id_ctx.user_data.handle));

        var name_ctx = name_ctx: {
            const path = try expectPath(allocator, "name");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path, null)) {
                .field => |found| break :name_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer
        try testing.expectEqual(@ptrToInt(person.name.ptr), @ptrToInt(name_ctx.user_data.handle));
    }

    test "FFI Write" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContext(user_data);

        var writer = list.writer();

        try interpolateCtx(writer, person_ctx, "id", .Unescaped);
        try testing.expectEqualStrings("100", list.items);

        list.clearAndFree();

        try interpolateCtx(writer, person_ctx, "name", .Unescaped);
        try testing.expectEqualStrings("Angus McGyver", list.items);

        list.clearAndFree();
    }

    test "FFI Render" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 42,
            .name = "Peter",
        };

        var user_data = Person.getUserData(&person);
        var text = try mustache.allocRenderText(allocator, "Hello {{name}}, your Id is {{id}}", user_data);
        defer allocator.free(text);

        try testing.expectEqualStrings("Hello Peter, your Id is 42", text);
    }
};
