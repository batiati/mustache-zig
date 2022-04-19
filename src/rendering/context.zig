const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;
const Element = mustache.Element;

const rendering = @import("rendering.zig");

const lambda = @import("lambda.zig");
const LambdaContext = lambda.LambdaContext;

const invoker = @import("invoker.zig");
const Fields = invoker.Fields;

const map = @import("partials_map.zig");

pub fn PathResolution(comptime Payload: type) type {
    return union(enum) {

        ///
        /// The path could no be found on the current context
        /// This result indicates that the path should be resolved against the parent context
        /// For example:
        /// context = .{ name = "Phill" };
        /// path = "address"
        NotFoundInContext,

        ///
        /// Parts of the path could not be found on the current context.
        /// This result indicates that the path is broken and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .address = .{ street = "Wall St, 50", } };
        /// path = "address.country"
        ChainBroken,

        ///
        /// The path could be resolved against the current context, but the iterator was fully consumed
        /// This result indicates that the path is valid, but not to be rendered and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .visible = false  };
        /// path = "visible"
        IteratorConsumed,

        ///
        /// The lambda could be resolved against the current context,
        /// The payload is the result returned by "action_fn"
        Lambda: Payload,

        ///
        /// The field could be resolved against the current context
        /// The payload is the result returned by "action_fn"
        Field: Payload,
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
    const Impl = ContextImpl(Writer, @TypeOf(data), PartialsMap, options);
    return Impl.context(data);
}

const FlattenedType = [4]usize;

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
            get: fn (*const anyopaque, []const u8, ?usize) PathResolution(Self),
            interpolate: fn (*const anyopaque, *DataRender, []const u8, Escape) (Allocator.Error || Writer.Error)!PathResolution(void),
            expandLambda: fn (*const anyopaque, *DataRender, []const u8, []const u8, Escape, Delimiters) (Allocator.Error || Writer.Error)!PathResolution(void),
        };

        pub const Iterator = struct {
            data: union(enum) {
                Empty,
                Lambda: Self,
                Sequence: struct {
                    context: *const Self,
                    path: []const u8,
                    state: union(enum) {
                        Fetching: struct {
                            item: Self,
                            index: usize,
                        },
                        Finished,
                    },

                    fn fetch(self: *@This(), index: usize) ?Self {
                        const result = self.context.vtable.get(
                            &self.context.ctx,
                            self.path,
                            index,
                        );

                        return switch (result) {
                            .Field => |item| item,
                            .IteratorConsumed => null,
                            else => {
                                assert(false);
                                unreachable;
                            },
                        };
                    }
                },
            },

            fn initEmpty() Iterator {
                return .{
                    .data = .Empty,
                };
            }

            fn initLambda(lambda_ctx: Self) Iterator {
                return .{
                    .data = .{
                        .Lambda = lambda_ctx,
                    },
                };
            }

            fn initSequence(parent_ctx: *const Self, path: []const u8, item: Self) Iterator {
                return .{
                    .data = .{
                        .Sequence = .{
                            .context = parent_ctx,
                            .path = path,
                            .state = .{
                                .Fetching = .{
                                    .item = item,
                                    .index = 0,
                                },
                            },
                        },
                    },
                };
            }

            pub inline fn lambda(self: *Iterator) ?Self {
                return switch (self.data) {
                    .Lambda => |item| item,
                    else => null,
                };
            }

            pub inline fn truthy(self: *Iterator) bool {
                switch (self.data) {
                    .Empty => return false,
                    .Lambda => return true,
                    .Sequence => |sequence| switch (sequence.state) {
                        .Fetching => return true,
                        .Finished => return false,
                    },
                }
            }

            pub fn next(self: *Iterator) ?Self {
                switch (self.data) {
                    .Lambda, .Empty => return null,
                    .Sequence => |*sequence| switch (sequence.state) {
                        .Fetching => |current| {
                            const next_index = current.index + 1;
                            if (sequence.fetch(next_index)) |item| {
                                sequence.state = .{
                                    .Fetching = .{
                                        .item = item,
                                        .index = next_index,
                                    },
                                };
                            } else {
                                sequence.state = .Finished;
                            }

                            return current.item;
                        },
                        .Finished => return null,
                    },
                }
            }

            pub inline fn hasNext(self: *Iterator) bool {
                return switch (self.data) {
                    .Lambda, .Empty => false,
                    .Sequence => |sequence| switch (sequence.state) {
                        .Fetching => true,
                        .Finished => false,
                    },
                };
            }
        };

        ctx: FlattenedType = undefined,
        vtable: *const VTable,

        pub inline fn get(self: Self, path: []const u8) PathResolution(Self) {
            return self.vtable.get(&self.ctx, path, null);
        }

        pub fn iterator(self: *const Self, path: []const u8) PathResolution(Iterator) {
            const result = self.vtable.get(&self.ctx, path, 0);

            return switch (result) {
                .Field => |item| .{
                    .Field = Iterator.initSequence(self, path, item),
                },
                .IteratorConsumed => .{
                    .Field = Iterator.initEmpty(),
                },
                .Lambda => |item| .{
                    .Field = Iterator.initLambda(item),
                },
                .ChainBroken => .ChainBroken,
                .NotFoundInContext => .NotFoundInContext,
            };
        }

        pub inline fn interpolate(
            self: Self,
            data_render: *DataRender,
            path: []const u8,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try self.vtable.interpolate(&self.ctx, data_render, path, escape);
        }

        pub inline fn expandLambda(
            self: Self,
            data_render: *DataRender,
            path: []const u8,
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
            .interpolate = interpolate,
            .expandLambda = expandLambda,
        };

        const is_zero_size = @sizeOf(Data) == 0;
        const PATH_SEPARATOR = ".";
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

        fn get(ctx: *const anyopaque, path: []const u8, index: ?usize) PathResolution(ContextInterface) {
            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return Invoker.get(
                getData(ctx),
                &path_iterator,
                index,
            );
        }

        fn interpolate(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: []const u8,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try Invoker.interpolate(
                data_render,
                getData(ctx),
                &path_iterator,
                escape,
            );
        }

        fn expandLambda(
            ctx: *const anyopaque,
            data_render: *DataRender,
            path: []const u8,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try Invoker.expandLambda(
                data_render,
                getData(ctx),
                inner_text,
                escape,
                delimiters,
                &path_iterator,
            );
        }

        inline fn getData(ctx: *const anyopaque) Data {
            return if (is_zero_size) undefined else (@ptrCast(*const Data, @alignCast(@alignOf(Data), ctx))).*;
        }
    };
}

test {
    _ = invoker;
    _ = lambda;
    _ = struct_tests;
}
const testing = std.testing;

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

    const dummy_options = RenderOptions{ .Template = .{} };
    const DummyPartialsMap = map.PartialsMap(void, dummy_options);
    const dummy_map = DummyPartialsMap.init({});

    fn interpolate(writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const Data = @TypeOf(data);
        const by_value = comptime Fields.byValue(Data);

        const Writer = @TypeOf(writer);
        var ctx = getContext(Writer, if (by_value) data else @as(*const Data, &data), DummyPartialsMap, dummy_options);

        try interpolateCtx(writer, ctx, path, .Unescaped);
    }

    fn interpolateCtx(writer: anytype, ctx: Context(@TypeOf(writer), DummyPartialsMap, dummy_options), path: []const u8, escape: Escape) anyerror!void {
        const RenderEngine = rendering.RenderEngine(@TypeOf(writer), DummyPartialsMap, dummy_options);

        var stack = RenderEngine.ContextStack{
            .parent = null,
            .ctx = ctx,
        };

        var data_render = RenderEngine.DataRender{
            .stack = &stack,
            .out_writer = .{ .Writer = writer },
            .partials_map = undefined,
            .indentation_queue = undefined,
        };

        switch (try ctx.interpolate(&data_render, path, escape)) {
            .Lambda => {
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

        list.clearAndFree();

        try interpolateCtx(writer, person_ctx, "address.street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Address

        var address_ctx = switch (person_ctx.get("address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        list.clearAndFree();
        try interpolateCtx(writer, address_ctx, "street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Street

        var street_ctx = switch (address_ctx.get("street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        list.clearAndFree();

        try interpolateCtx(writer, street_ctx, "", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        try interpolateCtx(writer, street_ctx, ".", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);
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

        list.clearAndFree();

        try interpolateCtx(writer, person_ctx, "indication.address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Indication

        var indication_ctx = switch (person_ctx.get("indication")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        list.clearAndFree();
        try interpolateCtx(writer, indication_ctx, "address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Address

        var address_ctx = switch (indication_ctx.get("address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        list.clearAndFree();
        try interpolateCtx(writer, address_ctx, "street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Street

        var street_ctx = switch (address_ctx.get("street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        list.clearAndFree();

        try interpolateCtx(writer, street_ctx, "", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        try interpolateCtx(writer, street_ctx, ".", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const Writer = @TypeOf(std.io.null_writer);
        var person_ctx = getContext(Writer, &person, DummyPartialsMap, dummy_options);

        // Person.address
        var address_ctx = switch (person_ctx.get("address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        var wrong_address = person_ctx.get("wrong_address");
        try testing.expect(wrong_address == .NotFoundInContext);

        // Person.address.street
        var street_ctx = switch (address_ctx.get("street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        var wrong_street = address_ctx.get("wrong_street");
        try testing.expect(wrong_street == .NotFoundInContext);

        // Person.address.street.len
        var street_len_ctx = switch (street_ctx.get("len")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        _ = street_len_ctx;

        var wrong_len = street_ctx.get("wrong_len");
        try testing.expect(wrong_len == .NotFoundInContext);
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

        var iterator = switch (ctx.iterator("items")) {
            .Field => |found| found,
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
            var iterator = switch (ctx.iterator("active")) {
                .Field => |found| found,
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
            var iterator = switch (ctx.iterator("indication.active")) {
                .Field => |found| found,
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
            var iterator = switch (ctx.iterator("additional_information")) {
                .Field => |found| found,
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
            var iterator = switch (ctx.iterator("indication.additional_information")) {
                .Field => |found| found,
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
