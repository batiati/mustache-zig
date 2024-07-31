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
const ContextSource = rendering.ContextSource;

const context = @import("../../context.zig");
const PathResolutionType = context.PathResolutionType;
const Escape = context.Escape;
const ContextIteratorType = context.ContextIteratorType;

const ffi_exports = @import("../../../exports.zig");
const extern_types = @import("../../../ffi/extern_types.zig");

/// FFI context can resolve paths from foreign elements
/// This struct implements the expected context interface using static dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn ContextType(
    comptime Writer: type,
    comptime PartialsMap: type,
    comptime UserData: type,
    comptime options: RenderOptions,
) type {
    const RenderEngine = rendering.RenderEngineType(.ffi, Writer, PartialsMap, UserData, options);
    const DataRender = RenderEngine.DataRender;

    return struct {
        const Context = @This();

        /// Implements a Writer exposing a function pointer to be called from the FFI side
        pub const FfiWriter = struct {
            data_render: *DataRender,
            escape: Escape,

            fn write(ctx: ?*anyopaque, value: ?[*]const u8, len: u32) callconv(.C) extern_types.Status {
                if (ctx) |handle| {
                    if (value) |buffer| {
                        var self = @as(*@This(), @ptrCast(@alignCast(handle)));
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
            ctx: Context,
        };

        pub const ContextIterator = ContextIteratorType(Context, DataRender);

        user_data: extern_types.UserData = undefined,

        pub fn ContextType(user_data: extern_types.UserData) Context {
            return .{
                .user_data = user_data,
            };
        }

        pub inline fn get(self: Context, _: *DataRender, path: Element.Path, index: ?usize) PathResolutionType(Context) {
            if (self.user_data.get != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @as(u32, @intCast(path[0].len)),
                        .next = null,
                    };

                    if (path.len == 1) {
                        return self.callGet(&root_path, index);
                    } else {
                        @setCold(true);
                        return self.getFromPath(&root_path, &root_path, path[1..], index);
                    }
                } else {
                    return self.callGet(null, index);
                }
            }

            return .chain_broken;
        }

        fn getFromPath(
            self: Context,
            root_path: *const extern_types.PathPart,
            leaf_path: *extern_types.PathPart,
            path: Element.Path,
            index: ?usize,
        ) PathResolutionType(Context) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @as(u32, @intCast(path[0].len)),
                    .next = null,
                };

                leaf_path.next = &current_part;
            } else {
                leaf_path.next = null;
            }

            if (path.len > 1) {
                return self.getFromPath(root_path, &current_part, path[1..], index);
            } else {
                return self.callGet(root_path, index);
            }
        }

        inline fn callGet(
            self: Context,
            root_path: ?*const extern_types.PathPart,
            index: ?usize,
        ) PathResolutionType(Context) {
            var out_value: extern_types.UserData = undefined;
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = @as(u32, @intCast(index orelse 0)),
                .has_index = index != null,
            };

            const ret = self.user_data.get.?(self.user_data.handle, &ffi_path, &out_value);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                .CHAIN_BROKEN => .chain_broken,
                .ITERATOR_CONSUMED => .iterator_consumed,
                .FIELD => .{ .field = RenderEngine.getContextType(out_value) },
                .LAMBDA => .{ .lambda = RenderEngine.getContextType(out_value) },
            };
        }

        pub inline fn capacityHint(
            self: Context,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolutionType(usize) {
            _ = data_render;
            if (self.user_data.capacityHint != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @as(u32, @intCast(path[0].len)),
                        .next = null,
                    };

                    if (path.len == 1) {
                        return self.callCapacityHint(&root_path);
                    } else {
                        @setCold(true);
                        return self.capacityHintFromPath(&root_path, &root_path, path[1..]);
                    }
                } else {
                    return self.callCapacityHint(null);
                }
            }

            return .chain_broken;
        }

        fn capacityHintFromPath(
            self: Context,
            root_path: *const extern_types.PathPart,
            leaf_path: *extern_types.PathPart,
            path: Element.Path,
        ) PathResolutionType(usize) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @as(u32, @intCast(path[0].len)),
                    .next = null,
                };

                leaf_path.next = &current_part;
            } else {
                leaf_path.next = null;
            }

            if (path.len > 1) {
                return self.capacityHintFromPath(root_path, &current_part, path[1..]);
            } else {
                return self.callCapacityHint(root_path);
            }
        }

        inline fn callCapacityHint(
            self: Context,
            root_path: ?*const extern_types.PathPart,
        ) PathResolutionType(usize) {
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = 0,
                .has_index = false,
            };

            var capacity: u32 = undefined;
            const ret = self.user_data.capacityHint.?(self.user_data.handle, &ffi_path, &capacity);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                .CHAIN_BROKEN => .chain_broken,
                .ITERATOR_CONSUMED => .iterator_consumed,
                .FIELD => .{ .field = capacity },
                .LAMBDA => .{ .lambda = capacity },
            };
        }

        pub inline fn interpolate(
            self: Context,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            if (self.user_data.interpolate != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @as(
                            u32,
                            @intCast(path[0].len),
                        ),
                        .next = null,
                    };

                    if (path.len == 1) {
                        return try self.callInterpolate(
                            data_render,
                            &root_path,
                            escape,
                        );
                    } else {
                        @setCold(true);
                        return try self.interpolateFromPath(
                            data_render,
                            &root_path,
                            &root_path,
                            path[1..],
                            escape,
                        );
                    }
                } else {
                    return try self.callInterpolate(
                        data_render,
                        null,
                        escape,
                    );
                }
            }

            return PathResolutionType(void).chain_broken;
        }

        fn interpolateFromPath(
            self: Context,
            data_render: *DataRender,
            root_path: *const extern_types.PathPart,
            leaf_path: *extern_types.PathPart,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @as(u32, @intCast(path[0].len)),
                    .next = null,
                };

                leaf_path.next = &current_part;
            } else {
                leaf_path.next = null;
            }

            if (path.len > 1) {
                return try self.interpolateFromPath(
                    data_render,
                    root_path,
                    &current_part,
                    path[1..],
                    escape,
                );
            } else {
                return try self.callInterpolate(
                    data_render,
                    root_path,
                    escape,
                );
            }
        }

        inline fn callInterpolate(
            self: Context,
            data_render: *DataRender,
            root_path: ?*const extern_types.PathPart,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = 0,
                .has_index = false,
            };

            var writer = FfiWriter{
                .data_render = data_render,
                .escape = escape,
            };

            const ret = self.user_data.interpolate.?(&writer, FfiWriter.write, self.user_data.handle, &ffi_path);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                .CHAIN_BROKEN => .chain_broken,
                .ITERATOR_CONSUMED => .iterator_consumed,
                .FIELD => .field,
                .LAMBDA => .lambda,
            };
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

            // TODO: not supported yet
            return .chain_broken;
        }

        pub fn iterator(
            self: *const Context,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolutionType(ContextIterator) {
            const result = self.get(data_render, path, 0);

            return switch (result) {
                .field => |item| .{
                    .field = ContextIterator.initSequence(self, path, data_render, item),
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
    };
}

test {
    _ = context_tests;
}

const context_tests = struct {
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyPartialsMap = map.PartialsMapType(void, dummy_options);
    const DummyWriter = std.ArrayList(u8).Writer;
    const DummyRenderEngine = rendering.RenderEngineType(.ffi, DummyWriter, DummyPartialsMap, void, dummy_options);

    const parsing = @import("../../../parsing/parser.zig");
    const DummyParser = parsing.ParserType(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
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

        const path = try expectPath(testing.allocator, identifier);
        defer Element.destroyPath(testing.allocator, false, path);

        switch (try ctx.interpolate(&data_render, path, escape)) {
            .lambda => {
                _ = try ctx.expandLambda(&data_render, path, "", escape, .{});
            },
            else => {},
        }
    }

    const Person = struct {
        id: u32,
        name: []const u8,
        boss: ?*Person = null,

        pub fn get(user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path, out_value: *extern_types.UserData) callconv(.C) extern_types.PathResolution {
            if (path.root) |root| {
                var path_part = root;
                const path_value = path_part.value[0..path_part.size];

                var person = getSelf(user_data_handle);
                if (std.mem.eql(u8, path_value, "id")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = Person.getUserData(&person.id);
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = Person.getUserData(person.name.ptr);
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "boss")) {
                    if (path.has_index) {
                        if (person.boss == null or path.index > 0) return .ITERATOR_CONSUMED;
                    } else if (person.boss == null) {
                        return .CHAIN_BROKEN;
                    }

                    if (root.next == null) {
                        out_value.* = Person.getUserData(person.boss.?);
                        return .FIELD;
                    } else {
                        var next_path = extern_types.Path{
                            .root = root.next,
                            .index = path.index,
                            .has_index = path.has_index,
                        };

                        return get(person.boss.?, &next_path, out_value);
                    }
                }
            }

            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn capacityHint(user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path, out_value: *u32) callconv(.C) extern_types.PathResolution {
            if (path.root) |root| {
                var path_part = root;
                const path_value = path_part.value[0..path_part.size];

                const person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = @as(u32, @intCast(std.fmt.count("{}", .{person.id})));
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = @as(u32, @intCast(person.name.len));
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "boss")) {
                    if (person.boss == null) return .CHAIN_BROKEN;
                    if (root.next == null) {
                        out_value.* = 0;
                        return .FIELD;
                    } else {
                        var next_path = extern_types.Path{
                            .root = root.next,
                            .index = path.index,
                            .has_index = path.has_index,
                        };

                        return capacityHint(person.boss.?, &next_path, out_value);
                    }
                }
            }

            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn interpolate(writer_handle: extern_types.WriterHandle, writer_fn: extern_types.WriteFn, user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path) callconv(.C) extern_types.PathResolution {
            if (path.root) |root| {
                var path_part = root;
                const path_value = path_part.value[0..path_part.size];

                // Using the FFI external function to interpolate,
                // Just like a foreign language would do.

                const person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    var buffer: [64]u8 = undefined;
                    const len = std.fmt.formatIntBuf(&buffer, person.id, 10, .lower, .{});

                    const ret = writer_fn(writer_handle, &buffer, @intCast(len));
                    if (ret != .SUCCESS) return .CHAIN_BROKEN;

                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;

                    const ret = writer_fn(writer_handle, person.name.ptr, @intCast(person.name.len));
                    if (ret != .SUCCESS) return .CHAIN_BROKEN;

                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "boss")) {
                    if (person.boss == null) return .CHAIN_BROKEN;
                    if (root.next == null) {
                        return .FIELD;
                    } else {
                        var next_path = extern_types.Path{
                            .root = root.next,
                            .index = path.index,
                            .has_index = path.has_index,
                        };

                        return interpolate(
                            writer_handle,
                            writer_fn,
                            person.boss.?,
                            &next_path,
                        );
                    }
                }
            }

            return .NOT_FOUND_IN_CONTEXT;
        }

        pub fn expandLambda(
            lambda_handle: extern_types.LambdaHandle,
            user_data_handle: extern_types.UserDataHandle,
            path: *const extern_types.Path,
        ) callconv(.C) extern_types.PathResolution {
            _ = lambda_handle;
            _ = user_data_handle;
            _ = path;

            return .NOT_FOUND_IN_CONTEXT;
        }

        fn getSelf(user_data_handle: extern_types.UserDataHandle) *const Person {
            return @ptrCast(@alignCast(user_data_handle));
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

    test "FFI context get" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        const user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContextType(user_data);
        var data_render: DummyRenderEngine.DataRender = undefined;

        const id_ctx = id_ctx: {
            const path = try expectPath(allocator, "id");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(&data_render, path, null)) {
                .field => |found| break :id_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer
        try testing.expectEqual(@intFromPtr(&person.id), @intFromPtr(id_ctx.user_data.handle));

        const name_ctx = name_ctx: {
            const path = try expectPath(allocator, "name");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(&data_render, path, null)) {
                .field => |found| break :name_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer
        try testing.expectEqual(@intFromPtr(person.name.ptr), @intFromPtr(name_ctx.user_data.handle));
    }

    test "FFI context get children" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var next_person = Person{
            .id = 101,
            .name = "Peter Thornton",
        };

        person.boss = &next_person;

        const user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContextType(user_data);
        var data_render: DummyRenderEngine.DataRender = undefined;

        const id_ctx = id_ctx: {
            const path = try expectPath(allocator, "boss.id");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(&data_render, path, null)) {
                .field => |found| break :id_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer.
        try testing.expectEqual(@intFromPtr(&person.boss.?.id), @intFromPtr(id_ctx.user_data.handle));

        const name_ctx = name_ctx: {
            const path = try expectPath(allocator, "boss.name");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(&data_render, path, null)) {
                .field => |found| break :name_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        // Expects that the context was set with the field address
        // The context can be set with any value, this test sets a pointer
        try testing.expectEqual(@intFromPtr(person.boss.?.name.ptr), @intFromPtr(name_ctx.user_data.handle));
    }

    test "FFI Write" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        const user_data = Person.getUserData(&person);
        const person_ctx = DummyRenderEngine.getContextType(user_data);

        const writer = list.writer();

        try interpolateCtx(writer, person_ctx, "id", .Unescaped);
        try testing.expectEqualStrings("100", list.items);

        list.clearAndFree();

        try interpolateCtx(writer, person_ctx, "name", .Unescaped);
        try testing.expectEqualStrings("Angus McGyver", list.items);

        list.clearAndFree();
    }

    test "FFI Write children" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var next_person = Person{
            .id = 101,
            .name = "Peter Thornton",
        };

        person.boss = &next_person;
        const user_data = Person.getUserData(&person);
        const person_ctx = DummyRenderEngine.getContextType(user_data);

        const writer = list.writer();

        try interpolateCtx(writer, person_ctx, "boss.id", .Unescaped);
        try testing.expectEqualStrings("101", list.items);

        list.clearAndFree();

        try interpolateCtx(writer, person_ctx, "boss.name", .Unescaped);
        try testing.expectEqualStrings("Peter Thornton", list.items);

        list.clearAndFree();
    }

    test "FFI Render" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        const template_text = "Hello {{name}}, your Id is {{id}}";
        const expected_text = "Hello Angus McGyver, your Id is 100";

        const user_data = Person.getUserData(&person);
        const text = try mustache.allocRenderText(allocator, template_text, user_data);
        defer allocator.free(text);

        try testing.expectEqualStrings(expected_text, text);
    }

    test "FFI children render" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var next_person = Person{
            .id = 101,
            .name = "Peter Thornton",
        };

        person.boss = &next_person;

        const template_text =
            \\Hello {{name}}, your Id is {{id}}
            \\your boss is {{boss.name}}, Id {{boss.id}}
        ;

        const expected_text =
            \\Hello Angus McGyver, your Id is 100
            \\your boss is Peter Thornton, Id 101
        ;

        const user_data = Person.getUserData(&person);
        const text = try mustache.allocRenderText(allocator, template_text, user_data);
        defer allocator.free(text);

        try testing.expectEqualStrings(expected_text, text);
    }

    test "FFI Section render" {
        const allocator = testing.allocator;

        var person = Person{
            .id = 100,
            .name = "Angus McGyver",
        };

        var next_person = Person{
            .id = 101,
            .name = "Peter Thornton",
        };

        person.boss = &next_person;

        const template_text =
            \\Hello {{name}}, your Id is {{id}}
            \\your boss is {{#boss}}{{name}}, Id {{id}}{{/boss}}
        ;

        const expected_text =
            \\Hello Angus McGyver, your Id is 100
            \\your boss is Peter Thornton, Id 101
        ;

        const user_data = Person.getUserData(&person);
        const text = try mustache.allocRenderText(allocator, template_text, user_data);
        defer allocator.free(text);

        try testing.expectEqualStrings(expected_text, text);
    }
};
