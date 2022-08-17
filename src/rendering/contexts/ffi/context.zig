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

        pub inline fn get(self: Self, path: Element.Path, index: ?usize) PathResolution(Self) {
            if (self.user_data.get != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @intCast(u32, path[0].len),
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

        fn getFromPath(self: Self, root_path: *const extern_types.PathPart, leaf_path: *extern_types.PathPart, path: Element.Path, index: ?usize) PathResolution(Self) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @intCast(u32, path[0].len),
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

        inline fn callGet(self: Self, root_path: ?*const extern_types.PathPart, index: ?usize) PathResolution(Self) {
            var out_value: extern_types.UserData = undefined;
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = @intCast(u32, index orelse 0),
                .has_index = index != null,
            };

            var ret = self.user_data.get.?(self.user_data.handle, &ffi_path, &out_value);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                .CHAIN_BROKEN => .chain_broken,
                .ITERATOR_CONSUMED => .iterator_consumed,
                .FIELD => .{ .field = RenderEngine.getContext(out_value) },
                .LAMBDA => .{ .lambda = RenderEngine.getContext(out_value) },
            };
        }

        pub inline fn capacityHint(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            _ = data_render;
            if (self.user_data.capacityHint != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @intCast(u32, path[0].len),
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

        fn capacityHintFromPath(self: Self, root_path: *const extern_types.PathPart, leaf_path: *extern_types.PathPart, path: Element.Path) PathResolution(usize) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @intCast(u32, path[0].len),
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

        inline fn callCapacityHint(self: Self, root_path: ?*const extern_types.PathPart) PathResolution(usize) {
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = 0,
                .has_index = false,
            };

            var capacity: u32 = undefined;
            var ret = self.user_data.capacityHint.?(self.user_data.handle, &ffi_path, &capacity);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => .not_found_in_context,
                .CHAIN_BROKEN => .chain_broken,
                .ITERATOR_CONSUMED => .iterator_consumed,
                .FIELD => .{ .field = capacity },
                .LAMBDA => .{ .lambda = capacity },
            };
        }

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            if (self.user_data.interpolate != null) {
                if (path.len > 0) {
                    var root_path = extern_types.PathPart{
                        .value = path[0].ptr,
                        .size = @intCast(u32, path[0].len),
                        .next = null,
                    };

                    if (path.len == 1) {
                        return try self.callInterpolate(data_render, &root_path, escape);
                    } else {
                        @setCold(true);
                        return try self.interpolateFromPath(data_render, &root_path, &root_path, path[1..], escape);
                    }
                } else {
                    return try self.callInterpolate(data_render, null, escape);
                }
            }

            return PathResolution(void).chain_broken;
        }

        fn interpolateFromPath(self: Self, data_render: *DataRender, root_path: *const extern_types.PathPart, leaf_path: *extern_types.PathPart, path: Element.Path, escape: Escape) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var current_part: extern_types.PathPart = undefined;
            if (path.len > 0) {
                current_part = extern_types.PathPart{
                    .value = path[0].ptr,
                    .size = @intCast(u32, path[0].len),
                    .next = null,
                };

                leaf_path.next = &current_part;
            } else {
                leaf_path.next = null;
            }

            if (path.len > 1) {
                return try self.interpolateFromPath(data_render, root_path, &current_part, path[1..], escape);
            } else {
                return try self.callInterpolate(data_render, root_path, escape);
            }
        }

        inline fn callInterpolate(self: Self, data_render: *DataRender, root_path: ?*const extern_types.PathPart, escape: Escape) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var ffi_path: extern_types.Path = .{
                .root = root_path,
                .index = 0,
                .has_index = false,
            };

            var writer = FfiWriter{
                .data_render = data_render,
                .escape = escape,
            };

            var ret = self.user_data.interpolate.?(&writer, FfiWriter.write, self.user_data.handle, &ffi_path);

            return switch (ret) {
                .NOT_FOUND_IN_CONTEXT => PathResolution(void).not_found_in_context,
                .CHAIN_BROKEN => PathResolution(void).chain_broken,
                .ITERATOR_CONSUMED => PathResolution(void).iterator_consumed,
                .FIELD => PathResolution(void).field,
                .LAMBDA => PathResolution(void).lambda,
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
        boss: ?*Person = null,

        pub fn get(user_data_handle: extern_types.UserDataHandle, path: *const extern_types.Path, out_value: *extern_types.UserData) callconv(.C) extern_types.PathResolution {
            if (path.root) |root| {
                var path_part = root;
                var path_value = path_part.value[0..path_part.size];

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
                var path_value = path_part.value[0..path_part.size];

                var person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = @intCast(u32, std.fmt.count("{}", .{person.id}));
                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    out_value.* = @intCast(u32, person.name.len);
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
                var path_value = path_part.value[0..path_part.size];

                // Using the FFI external function to interpolate,
                // Just like a foreign language would do.

                var person = getSelf(user_data_handle);

                if (std.mem.eql(u8, path_value, "id")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;
                    var buffer: [64]u8 = undefined;
                    var len = std.fmt.formatIntBuf(&buffer, person.id, 10, .lower, .{});

                    var ret = writer_fn(writer_handle, &buffer, @intCast(u32, len));
                    if (ret != .SUCCESS) return .CHAIN_BROKEN;

                    return .FIELD;
                } else if (std.mem.eql(u8, path_value, "name")) {
                    if (root.next != null) return .NOT_FOUND_IN_CONTEXT;

                    var ret = writer_fn(writer_handle, person.name.ptr, @intCast(u32, person.name.len));
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

                        return interpolate(writer_handle, writer_fn, person.boss.?, &next_path);
                    }
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

        var user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContext(user_data);

        var id_ctx = id_ctx: {
            const path = try expectPath(allocator, "boss.id");
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
        try testing.expectEqual(@ptrToInt(&person.boss.?.id), @ptrToInt(id_ctx.user_data.handle));

        var name_ctx = name_ctx: {
            const path = try expectPath(allocator, "boss.name");
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
        try testing.expectEqual(@ptrToInt(person.boss.?.name.ptr), @ptrToInt(name_ctx.user_data.handle));
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
        var user_data = Person.getUserData(&person);
        var person_ctx = DummyRenderEngine.getContext(user_data);

        var writer = list.writer();

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

        var user_data = Person.getUserData(&person);
        var text = try mustache.allocRenderText(allocator, template_text, user_data);
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

        var user_data = Person.getUserData(&person);
        var text = try mustache.allocRenderText(allocator, template_text, user_data);
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

        var user_data = Person.getUserData(&person);
        var text = try mustache.allocRenderText(allocator, template_text, user_data);
        defer allocator.free(text);

        try testing.expectEqualStrings(expected_text, text);
    }
};
