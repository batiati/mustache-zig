const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const assert = std.debug.assert;
const testing = std.testing;

const json = std.json;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;
const Element = mustache.Element;

const rendering = @import("rendering.zig");

const lambda = @import("lambda.zig");
const LambdaContext = lambda.LambdaContext;

const invoker = @import("invoker.zig");
const Fields = invoker.Fields;
const FlattenedType = invoker.FlattenedType;

const map = @import("partials_map.zig");

pub fn PathResolution(comptime Payload: type) type {
    return union(enum) {
        /// The path could no be found on the current context
        /// This result indicates that the path should be resolved against the parent context
        /// For example:
        /// context = .{ name = "Phill" };
        /// path = "address"
        not_found_in_context,

        /// Parts of the path could not be found on the current context.
        /// This result indicates that the path is broken and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .address = .{ street = "Wall St, 50", } };
        /// path = "address.country"
        chain_broken,

        /// The path could be resolved against the current context, but the iterator was fully consumed
        /// This result indicates that the path is valid, but not to be rendered and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .visible = false  };
        /// path = "visible"
        iterator_consumed,

        /// The lambda could be resolved against the current context,
        /// The payload is the result returned by "action_fn"
        lambda: Payload,

        /// The field could be resolved against the current context
        /// The payload is the result returned by "action_fn"
        field: Payload,
    };
}

pub const Escape = enum {
    Escaped,
    Unescaped,
};

pub fn getContext(comptime Writer: type, data: anytype, comptime PartialsMap: type, comptime options: RenderOptions) Context: {
    const Data = @TypeOf(data);
    const by_value = Fields.byValue(Data);
    if (!by_value and !trait.isSingleItemPtr(Data)) @compileError("Expected a pointer to " ++ @typeName(Data));

    const RenderEngine = rendering.RenderEngine(Writer, PartialsMap, options);
    break :Context RenderEngine.Context;
} {
    const Data = @TypeOf(data);

    if (comptime Data == json.Value or (trait.isSingleItemPtr(Data) and meta.Child(Data) == json.Value)) {
        const Impl = JsonContextImpl(Writer, PartialsMap, options);
        return Impl.context(data);
    } else if (Data == json.ValueTree or (comptime trait.isSingleItemPtr(Data) and meta.Child(Data) == json.ValueTree)) {
        const Impl = JsonContextImpl(Writer, PartialsMap, options);
        return Impl.context(data.root);
    } else {
        const Impl = ContextImpl(Writer, Data, PartialsMap, options);
        return Impl.context(data);
    }
}

pub fn Context(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(Writer, PartialsMap, options);
    const DataRender = RenderEngine.DataRender;

    return struct {
        const Self = @This();

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: Self,
        };

        const VTable = struct {
            get: fn (*const anyopaque, Element.Path, ?usize) PathResolution(Self),
            capacityHint: fn (*const anyopaque, *DataRender, Element.Path) PathResolution(usize),
            interpolate: fn (*const anyopaque, *DataRender, Element.Path, Escape) (Allocator.Error || Writer.Error)!PathResolution(void),
            expandLambda: fn (*const anyopaque, *DataRender, Element.Path, []const u8, Escape, Delimiters) (Allocator.Error || Writer.Error)!PathResolution(void),
        };

        pub const Iterator = struct {
            data: union(enum) {
                empty,
                lambda: Self,
                sequence: struct {
                    context: *const Self,
                    path: Element.Path,
                    state: union(enum) {
                        fetching: struct {
                            item: Self,
                            index: usize,
                        },
                        finished,
                    },

                    fn fetch(self: @This(), index: usize) ?Self {
                        const result = self.context.vtable.get(
                            &self.context.ctx,
                            self.path,
                            index,
                        );

                        return switch (result) {
                            .field => |item| item,
                            .iterator_consumed => null,
                            else => unreachable,
                        };
                    }
                },
            },

            fn initEmpty() Iterator {
                return .{
                    .data = .empty,
                };
            }

            fn initLambda(lambda_ctx: Self) Iterator {
                return .{
                    .data = .{
                        .lambda = lambda_ctx,
                    },
                };
            }

            fn initSequence(parent_ctx: *const Self, path: Element.Path, item: Self) Iterator {
                return .{
                    .data = .{
                        .sequence = .{
                            .context = parent_ctx,
                            .path = path,
                            .state = .{
                                .fetching = .{
                                    .item = item,
                                    .index = 0,
                                },
                            },
                        },
                    },
                };
            }

            pub fn lambda(self: Iterator) ?Self {
                return switch (self.data) {
                    .lambda => |item| item,
                    else => null,
                };
            }

            pub inline fn truthy(self: Iterator) bool {
                switch (self.data) {
                    .empty => return false,
                    .lambda => return true,
                    .sequence => |sequence| switch (sequence.state) {
                        .fetching => return true,
                        .finished => return false,
                    },
                }
            }

            pub fn next(self: *Iterator) ?Self {
                switch (self.data) {
                    .lambda, .empty => return null,
                    .sequence => |*sequence| switch (sequence.state) {
                        .fetching => |current| {
                            const next_index = current.index + 1;
                            if (sequence.fetch(next_index)) |item| {
                                sequence.state = .{
                                    .fetching = .{
                                        .item = item,
                                        .index = next_index,
                                    },
                                };
                            } else {
                                sequence.state = .finished;
                            }

                            return current.item;
                        },
                        .finished => return null,
                    },
                }
            }
        };

        ctx: FlattenedType = undefined,
        vtable: *const VTable,

        pub inline fn get(self: Self, path: Element.Path) PathResolution(Self) {
            return self.vtable.get(&self.ctx, path, null);
        }

        pub inline fn capacityHint(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            return self.vtable.capacityHint(&self.ctx, data_render, path);
        }

        pub fn iterator(self: *const Self, path: Element.Path) PathResolution(Iterator) {
            const result = self.vtable.get(&self.ctx, path, 0);

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

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try self.vtable.interpolate(&self.ctx, data_render, path, escape);
        }

        pub inline fn expandLambda(
            self: Self,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try self.vtable.expandLambda(&self.ctx, data_render, path, inner_text, escape, delimiters);
        }
    };
}

fn ContextImpl(comptime Writer: type, comptime Data: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(Writer, PartialsMap, options);
    const ContextInterface = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;
    const Invoker = RenderEngine.Invoker;

    return struct {
        const vtable = ContextInterface.VTable{
            .get = get,
            .capacityHint = capacityHint,
            .interpolate = interpolate,
            .expandLambda = expandLambda,
        };

        const is_zero_size = @sizeOf(Data) == 0;
        const Self = @This();

        pub fn context(data: Data) ContextInterface {
            var interface = ContextInterface{
                .vtable = &vtable,
            };

            if (!is_zero_size) {
                if (comptime @sizeOf(Data) > @sizeOf(FlattenedType)) @compileError(std.fmt.comptimePrint("Type {s} size {} exceeds the maxinum by-val size of {}", .{ @typeName(Data), @sizeOf(Data), @sizeOf(FlattenedType) }));
                var ptr = @ptrCast(*Data, @alignCast(@alignOf(Data), &interface.ctx));
                ptr.* = data;
            }

            return interface;
        }

        fn get(ctx: *const anyopaque, path: Element.Path, index: ?usize) PathResolution(ContextInterface) {
            return Invoker.get(
                getData(ctx),
                path,
                index,
            );
        }

        fn capacityHint(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            return Invoker.capacityHint(
                data_render,
                getData(ctx),
                path,
            );
        }

        fn interpolate(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try Invoker.interpolate(
                data_render,
                getData(ctx),
                path,
                escape,
            );
        }

        fn expandLambda(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try Invoker.expandLambda(
                data_render,
                getData(ctx),
                inner_text,
                escape,
                delimiters,
                path,
            );
        }

        inline fn getData(ctx: *const anyopaque) Data {
            return if (is_zero_size) undefined else (@ptrCast(*const Data, @alignCast(@alignOf(Data), ctx))).*;
        }
    };
}

fn JsonContextImpl(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(Writer, PartialsMap, options);
    const ContextInterface = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;
    const Depth = enum { Root, Leaf };

    return struct {
        const vtable = ContextInterface.VTable{
            .get = get,
            .capacityHint = capacityHint,
            .interpolate = interpolate,
            .expandLambda = expandLambda,
        };

        const Self = @This();

        pub fn context(json_value: json.Value) ContextInterface {
            var interface = ContextInterface{
                .vtable = &vtable,
                .ctx = undefined,
            };

            const Data = json.Value;
            var ptr = @ptrCast(*Data, @alignCast(@alignOf(Data), &interface.ctx));
            ptr.* = json_value;

            return interface;
        }

        fn get(ctx: *const anyopaque, path: Element.Path, index: ?usize) PathResolution(ContextInterface) {
            const root = getJsonRoot(ctx);
            const value = getJsonValue(.Root, root, path, index);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| .{ .field = getContext(Writer, content, PartialsMap, options) },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        fn capacityHint(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolution(usize) {
            const root = getJsonRoot(ctx);
            const value = getJsonValue(.Root, root, path, null);

            return switch (value) {
                .not_found_in_context => .not_found_in_context,
                .chain_broken => .chain_broken,
                .iterator_consumed => .iterator_consumed,
                .field => |content| switch (content) {
                    .Bool => |boolean| return .{ .field = data_render.valueCapacityHint(boolean) },
                    .Integer => |integer| return .{ .field = data_render.valueCapacityHint(integer) },
                    .Float => |float| return .{ .field = data_render.valueCapacityHint(float) },
                    .NumberString => |number_string| return .{ .field = data_render.valueCapacityHint(number_string) },
                    .String => |string| return .{ .field = data_render.valueCapacityHint(string) },
                    .Array => |array| return .{ .field = data_render.valueCapacityHint(array.items) },
                    else => return .{ .field = 0 },
                },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            };
        }

        fn interpolate(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const root = getJsonRoot(ctx);
            const value = getJsonValue(.Root, root, path, null);

            switch (value) {
                .not_found_in_context => return .not_found_in_context,
                .chain_broken => return .chain_broken,
                .iterator_consumed => return .iterator_consumed,
                .field => |content| switch (content) {
                    .Bool => |boolean| try data_render.write(boolean, escape),
                    .Integer => |integer| try data_render.write(integer, escape),
                    .Float => |float| try data_render.write(float, escape),
                    .NumberString => |number_string| try data_render.write(number_string, escape),
                    .String => |string| try data_render.write(string, escape),
                    .Array => |array| try data_render.write(array.items, escape),
                    else => {},
                },
                .lambda => {
                    assert(false);
                    unreachable;
                },
            }

            return .field;
        }

        fn expandLambda(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            _ = ctx;
            _ = data_render;
            _ = path;
            _ = inner_text;
            _ = escape;
            _ = delimiters;

            // Json objects cannot have declared lambdas
            return PathResolution(void).chain_broken;
        }

        fn getJsonValue(depth: Depth, value: json.Value, path: Element.Path, index: ?usize) PathResolution(json.Value) {
            if (path.len == 0) {
                if (index) |current_index| {
                    switch (value) {
                        .Array => |array| if (array.items.len > current_index) {
                            return .{ .field = array.items[current_index] };
                        },
                        .Bool => |boolean| if (boolean == true and current_index == 0) {
                            return .{ .field = value };
                        },
                        else => if (current_index == 0) {
                            return .{ .field = value };
                        },
                        .Null => {},
                    }

                    return .iterator_consumed;
                } else {
                    return .{ .field = value };
                }
            } else {
                switch (value) {
                    .Object => |obj| {
                        const key = path[0];

                        if (obj.get(key)) |next_value| {
                            return getJsonValue(.Leaf, next_value, path[1..], index);
                        }
                    },

                    else => {},
                }
            }

            return if (depth == .Root) .not_found_in_context else .chain_broken;
        }

        inline fn getJsonRoot(ctx: *const anyopaque) json.Value {
            const Data = json.Value;
            return (@ptrCast(*const Data, @alignCast(@alignOf(Data), ctx))).*;
        }
    };
}

test {
    _ = invoker;
    _ = lambda;
    _ = struct_tests;
}

const struct_tests = struct {

    // Test model

    const Item = struct {
        name: []const u8,
        value: f32,
    };

    const Person = struct {

        // Fields

        id: u32,
        name: []const u8,
        address: struct {
            street: []const u8,
            region: enum { EU, US, RoW },
            zip: u64,
            contacts: struct {
                phone: []const u8,
                email: []const u8,
            },
            coordinates: struct {
                lon: f64,
                lat: f64,
            },
        },
        items: []const Item,
        salary: f32,
        indication: ?*Person,
        active: bool,
        additional_information: ?[]const u8,
        counter: usize = 0,
        buffer: [32]u8 = undefined,

        // Lambdas

        pub fn staticLambda(ctx: LambdaContext) !void {
            try ctx.write("1");
        }

        pub fn selfLambda(self: Person, ctx: LambdaContext) !void {
            try ctx.writeFormat("{}", .{self.name.len});
        }

        pub fn selfConstPtrLambda(self: *const Person, ctx: LambdaContext) !void {
            try ctx.writeFormat("{}", .{self.name.len});
        }

        pub fn selfMutPtrLambda(self: *Person, ctx: LambdaContext) !void {
            self.counter += 1;
            try ctx.writeFormat("{}", .{self.counter});
        }

        pub fn willFailStaticLambda(ctx: LambdaContext) error{Expected}!void {
            _ = ctx;
            return error.Expected;
        }

        pub fn willFailSelfLambda(self: Person, ctx: LambdaContext) error{Expected}!void {
            _ = self;
            ctx.write("unfinished") catch unreachable;
            return error.Expected;
        }

        pub fn anythingElse(int: i32) u32 {
            _ = int;
            return 42;
        }
    };

    fn getPerson() Person {
        var person_1 = testing.allocator.create(Person) catch unreachable;
        person_1.* = Person{
            .id = 1,
            .name = "John Doe",
            .address = .{
                .street = "far away street",
                .region = .EU,
                .zip = 99450,
                .contacts = .{
                    .phone = "555-9090",
                    .email = "jdoe@none.com",
                },
                .coordinates = .{
                    .lon = 41.40338,
                    .lat = 2.17403,
                },
            },
            .items = &[_]Item{
                .{ .name = "just one item", .value = 0.01 },
            },
            .salary = 75.00,
            .indication = null,
            .active = false,
            .additional_information = null,
        };

        var person_2 = Person{
            .id = 2,
            .name = "Someone Jr",
            .address = .{
                .street = "nearby",
                .region = .RoW,
                .zip = 333900,
                .contacts = .{
                    .phone = "555-9191",
                    .email = "smjr@herewego.com",
                },
                .coordinates = .{
                    .lon = 38.71471,
                    .lat = -9.13872,
                },
            },
            .items = &[_]Item{
                .{ .name = "item 1", .value = 100 },
                .{ .name = "item 2", .value = 200 },
            },
            .salary = 140.00,
            .indication = person_1,
            .active = true,
            .additional_information = "someone was here",
        };

        return person_2;
    }

    const dummy_options = RenderOptions{ .string = .{} };

    const DummyPartialsMap = map.PartialsMap(void, dummy_options);
    const DummyParser = @import("../parsing/parser.zig").Parser(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
    const dummy_map = DummyPartialsMap.init({});

    fn expectPath(allocator: Allocator, path: []const u8) !Element.Path {
        var parser = try DummyParser.init(allocator, "", .{});
        defer parser.deinit();

        return try parser.parsePath(path);
    }

    fn interpolate(writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const Data = @TypeOf(data);
        const by_value = comptime Fields.byValue(Data);

        const Writer = @TypeOf(writer);
        var ctx = getContext(Writer, if (by_value) data else @as(*const Data, &data), DummyPartialsMap, dummy_options);

        try interpolateCtx(writer, ctx, path, .Unescaped);
    }

    fn interpolateCtx(writer: anytype, ctx: Context(@TypeOf(writer), DummyPartialsMap, dummy_options), identifier: []const u8, escape: Escape) anyerror!void {
        const RenderEngine = rendering.RenderEngine(@TypeOf(writer), DummyPartialsMap, dummy_options);

        var stack = RenderEngine.ContextStack{
            .parent = null,
            .ctx = ctx,
        };

        var data_render = RenderEngine.DataRender{
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

    test "Write Int" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Nested access
        try interpolate(writer, person, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, &person, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);
    }

    test "Write Float" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Nested access
        try interpolate(writer, person, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative values
        try interpolate(writer, person, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, &person, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative Ref values
        try interpolate(writer, &person, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);
    }

    test "Write String" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Direct Len access
        try interpolate(writer, person, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Direct Ref Len access
        try interpolate(writer, &person, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested access
        try interpolate(writer, person, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, &person, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, &person, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Write Enum" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);
    }

    test "Write Bool" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.active");
        try testing.expectEqualStrings("false", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.active");
        try testing.expectEqualStrings("false", list.items);
    }

    test "Write Nullable" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Null Accress
        try interpolate(writer, person.indication, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Null Ref Accress
        try interpolate(writer, person.indication, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);
    }

    test "Write Not found" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested access
        try interpolate(writer, person, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Direct Ref access
        try interpolate(writer, &person, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested Ref access
        try interpolate(writer, &person, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);
    }

    test "Lambda - staticLambda" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "staticLambda");
        try testing.expectEqualStrings("1", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "staticLambda");
        try testing.expectEqualStrings("1", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.staticLambda");
        try testing.expectEqualStrings("1", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, &person, "staticLambda");
        try testing.expectEqualStrings("1", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.staticLambda");
        try testing.expectEqualStrings("1", list.items);

        list.clearAndFree();
    }

    test "Lambda - selfLambda" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "selfLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Ref access
        try interpolate(writer, &person, "selfLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.selfLambda");
        try testing.expectEqualStrings("8", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, &person, "selfLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.selfLambda");
        try testing.expectEqualStrings("8", list.items);

        list.clearAndFree();
    }

    test "Lambda - selfConstPtrLambda" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const person_const_ptr: *const Person = &person;
        const person_ptr: *Person = &person;

        var writer = list.writer();

        // Direct access
        try interpolate(writer, person, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Const Ref access

        try interpolate(writer, person_const_ptr, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Mut Ref access
        try interpolate(writer, person_ptr, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested pointer access
        try interpolate(writer, person, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", list.items);

        list.clearAndFree();

        // Nested const Ref access
        try interpolate(writer, person_const_ptr, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", list.items);

        list.clearAndFree();

        // Nested Ref access
        try interpolate(writer, person_ptr, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", list.items);

        list.clearAndFree();
    }

    test "Lambda - Write selfMutPtrLambda" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        {
            var person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Cannot be called from a context by value
            try interpolate(writer, person, "selfMutPtrLambda");
            try testing.expectEqualStrings("", list.items);

            list.clearAndFree();

            // Mutable pointer
            try interpolate(writer, person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("1", list.items);
            try testing.expect(person.indication.?.counter == 1);

            list.clearAndFree();

            try interpolate(writer, person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("2", list.items); // Called again, it's mutable
            try testing.expect(person.indication.?.counter == 2);

            list.clearAndFree();
        }

        {
            var person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Cannot be called from a context const
            const const_person_ptr: *const Person = &person;
            try interpolate(writer, const_person_ptr, "selfMutPtrLambda");
            try testing.expectEqualStrings("", list.items);

            list.clearAndFree();
        }

        {
            var person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Ref access
            try interpolate(writer, &person, "selfMutPtrLambda");
            try testing.expectEqualStrings("1", list.items);
            try testing.expect(person.counter == 1);

            list.clearAndFree();

            try interpolate(writer, &person, "selfMutPtrLambda");
            try testing.expectEqualStrings("2", list.items); //Called again, it's mutable
            try testing.expect(person.counter == 2);

            list.clearAndFree();

            // Nested pointer access
            try interpolate(writer, &person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("1", list.items);
            try testing.expect(person.indication.?.counter == 1);

            list.clearAndFree();

            try interpolate(writer, &person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("2", list.items); // Called again, it's mutable
            try testing.expect(person.indication.?.counter == 2);

            list.clearAndFree();
        }
    }

    test "Lambda - error handling" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        try interpolate(writer, person, "willFailStaticLambda");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        try interpolate(writer, person, "willFailSelfLambda");
        try testing.expectEqualStrings("unfinished", list.items);

        list.clearAndFree();
    }

    test "Lambda - Write invalid functions" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Unexpected arguments
        try interpolate(writer, person, "anythingElse");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();
    }

    test "Navigation" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Person

        var person_ctx = getContext(@TypeOf(writer), &person, DummyPartialsMap, dummy_options);

        {
            list.clearAndFree();

            try interpolateCtx(writer, person_ctx, "address.street", .Unescaped);
            try testing.expectEqualStrings("nearby", list.items);
        }

        // Address

        var address_ctx = address_ctx: {
            const path = try expectPath(allocator, "address");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path)) {
                .field => |found| break :address_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            list.clearAndFree();

            try interpolateCtx(writer, address_ctx, "street", .Unescaped);
            try testing.expectEqualStrings("nearby", list.items);
        }

        // Street

        var street_ctx = street_ctx: {
            const path = try expectPath(allocator, "street");
            defer Element.destroyPath(allocator, false, path);

            switch (address_ctx.get(path)) {
                .field => |found| break :street_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            list.clearAndFree();

            try interpolateCtx(writer, street_ctx, "", .Unescaped);
            try testing.expectEqualStrings("nearby", list.items);
        }

        {
            list.clearAndFree();

            try interpolateCtx(writer, street_ctx, ".", .Unescaped);
            try testing.expectEqualStrings("nearby", list.items);
        }
    }

    test "Navigation Pointers" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Person

        var person_ctx = getContext(@TypeOf(writer), &person, DummyPartialsMap, dummy_options);

        {
            list.clearAndFree();

            try interpolateCtx(writer, person_ctx, "indication.address.street", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }

        // Indication

        var indication_ctx = indication_ctx: {
            const path = try expectPath(allocator, "indication");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path)) {
                .field => |found| break :indication_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            list.clearAndFree();

            try interpolateCtx(writer, indication_ctx, "address.street", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }

        // Address

        var address_ctx = address_ctx: {
            const path = try expectPath(allocator, "address");
            defer Element.destroyPath(allocator, false, path);

            switch (indication_ctx.get(path)) {
                .field => |found| break :address_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            list.clearAndFree();

            try interpolateCtx(writer, address_ctx, "street", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }

        // Street

        var street_ctx = street_ctx: {
            const path = try expectPath(allocator, "street");
            defer Element.destroyPath(allocator, false, path);

            switch (address_ctx.get(path)) {
                .field => |found| break :street_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            list.clearAndFree();

            try interpolateCtx(writer, street_ctx, "", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }

        {
            list.clearAndFree();

            try interpolateCtx(writer, street_ctx, ".", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const Writer = @TypeOf(std.io.null_writer);
        var person_ctx = getContext(Writer, &person, DummyPartialsMap, dummy_options);

        const address_ctx = address_ctx: {
            const path = try expectPath(allocator, "address");
            defer Element.destroyPath(allocator, false, path);

            // Person.address
            switch (person_ctx.get(path)) {
                .field => |found| break :address_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            const path = try expectPath(allocator, "wrong_address");
            defer Element.destroyPath(allocator, false, path);

            var wrong_address = person_ctx.get(path);
            try testing.expect(wrong_address == .not_found_in_context);
        }

        const street_ctx = street_ctx: {
            const path = try expectPath(allocator, "street");
            defer Element.destroyPath(allocator, false, path);

            // Person.address.street
            switch (address_ctx.get(path)) {
                .field => |found| break :street_ctx found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            }
        };

        {
            const path = try expectPath(allocator, "wrong_street");
            defer Element.destroyPath(allocator, false, path);

            var wrong_street = address_ctx.get(path);
            try testing.expect(wrong_street == .not_found_in_context);
        }

        {
            const path = try expectPath(allocator, "len");
            defer Element.destroyPath(allocator, false, path);
            // Person.address.street.len
            var street_len_ctx = switch (street_ctx.get(path)) {
                .field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };
            _ = street_len_ctx;
        }

        {
            const path = try expectPath(allocator, "wrong_len");
            defer Element.destroyPath(allocator, false, path);

            var wrong_len = street_ctx.get(path);
            try testing.expect(wrong_len == .not_found_in_context);
        }
    }

    test "Iterator over slice" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var writer = list.writer();

        // Person
        var ctx = getContext(@TypeOf(writer), &person, DummyPartialsMap, dummy_options);

        const path = try expectPath(allocator, "items");
        defer Element.destroyPath(allocator, false, path);

        var iterator = switch (ctx.iterator(path)) {
            .field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        var item_1 = iterator.next() orelse {
            try testing.expect(false);
            unreachable;
        };

        list.clearAndFree();

        try interpolateCtx(writer, item_1, "name", .Unescaped);
        try testing.expectEqualStrings("item 1", list.items);

        var item_2 = iterator.next() orelse {
            try testing.expect(false);
            unreachable;
        };

        list.clearAndFree();

        try interpolateCtx(writer, item_2, "name", .Unescaped);
        try testing.expectEqualStrings("item 2", list.items);

        var no_more = iterator.next();
        try testing.expect(no_more == null);
    }

    test "Iterator over bool" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const Writer = @TypeOf(std.io.null_writer);
        var ctx = getContext(Writer, &person, DummyPartialsMap, dummy_options);

        {
            // iterator over true
            const path = try expectPath(allocator, "active");
            defer Element.destroyPath(allocator, false, path);

            var iterator = switch (ctx.iterator(path)) {
                .field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var item_1 = iterator.next();
            try testing.expect(item_1 != null);

            var no_more = iterator.next();
            try testing.expect(no_more == null);
        }

        {
            // iterator over false
            const path = try expectPath(allocator, "indication.active");
            defer Element.destroyPath(allocator, false, path);

            var iterator = switch (ctx.iterator(path)) {
                .field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var no_more = iterator.next();
            try testing.expect(no_more == null);
        }
    }

    test "Iterator over null" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const Writer = @TypeOf(std.io.null_writer);
        var ctx = getContext(Writer, &person, DummyPartialsMap, dummy_options);

        {
            // iterator over true
            const path = try expectPath(allocator, "additional_information");
            defer Element.destroyPath(allocator, false, path);

            var iterator = switch (ctx.iterator(path)) {
                .field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var item_1 = iterator.next();
            try testing.expect(item_1 != null);

            var no_more = iterator.next();
            try testing.expect(no_more == null);
        }

        {
            // iterator over false
            const path = try expectPath(allocator, "indication.additional_information");
            defer Element.destroyPath(allocator, false, path);

            var iterator = switch (ctx.iterator(path)) {
                .field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var no_more = iterator.next();
            try testing.expect(no_more == null);
        }
    }
};
