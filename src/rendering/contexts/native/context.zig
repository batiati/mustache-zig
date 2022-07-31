const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../../../mustache.zig");
const Element = mustache.Element;
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;

const context = @import("../../context.zig");
const Fields = context.Fields;
const PathResolution = context.PathResolution;
const Escape = context.Escape;
const LambdaContext = context.LambdaContext;
const ContextIterator = context.ContextIterator;

const rendering = @import("../../rendering.zig");
const map = @import("../../partials_map.zig");
const lambda = @import("lambda.zig");
const invoker = @import("invoker.zig");

/// This type is large enough to hold some context data such as a pointer, a slice, a nullable pointer/slice
/// and some common primitives passed by value like enums, integers, floats and nullable integer/floats
pub const FlattenedType = [4]usize;

/// Native context can resolve paths for zig structs and values
/// This struct implements the expected context interface using dynamic dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn ContextInterface(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(.native, Writer, PartialsMap, options);
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

        pub const Iterator = ContextIterator(Self);

        ctx: FlattenedType = undefined,
        vtable: *const VTable,

        pub inline fn get(self: Self, path: Element.Path, index: ?usize) PathResolution(Self) {
            return self.vtable.get(&self.ctx, path, index);
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

/// Implements the ContextInterface.VTable for the comptime-known data type.
pub fn ContextImpl(comptime Writer: type, comptime Data: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(.native, Writer, PartialsMap, options);
    const Interface = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;
    const Invoker = invoker.Invoker(Writer, PartialsMap, options);

    return struct {
        const vtable = Interface.VTable{
            .get = get,
            .capacityHint = capacityHint,
            .interpolate = interpolate,
            .expandLambda = expandLambda,
        };

        const is_zero_size = @sizeOf(Data) == 0;
        const Self = @This();

        pub fn context(data: Data) Interface {
            var interface = Interface{
                .vtable = &vtable,
            };

            if (!is_zero_size) {
                if (comptime @sizeOf(Data) > @sizeOf(FlattenedType)) @compileError(std.fmt.comptimePrint("Type {s} size {} exceeds the maxinum by-val size of {}", .{ @typeName(Data), @sizeOf(Data), @sizeOf(FlattenedType) }));
                var ptr = @ptrCast(*Data, @alignCast(@alignOf(Data), &interface.ctx));
                ptr.* = data;
            }

            return interface;
        }

        fn get(ctx: *const anyopaque, path: Element.Path, index: ?usize) PathResolution(Interface) {
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

test {
    _ = invoker;
    _ = Fields;
    _ = lambda;
    _ = context_tests;
}

const context_tests = struct {

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
    const DummyWriter = std.ArrayList(u8).Writer;
    const DummyRenderEngine = rendering.RenderEngine(.native, DummyWriter, DummyPartialsMap, dummy_options);

    const parsing = @import("../../../parsing/parser.zig");
    const DummyParser = parsing.Parser(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
    const dummy_map = DummyPartialsMap.init({});

    fn expectPath(allocator: Allocator, path: []const u8) !Element.Path {
        var parser = try DummyParser.init(allocator, "", .{});
        defer parser.deinit();

        return try parser.parsePath(path);
    }

    fn interpolate(writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const Data = @TypeOf(data);
        const by_value = comptime Fields.byValue(Data);

        var ctx = DummyRenderEngine.getContext(if (by_value) data else @as(*const Data, &data));

        try interpolateCtx(writer, ctx, path, .Unescaped);
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

        var person_ctx = DummyRenderEngine.getContext(&person);

        {
            list.clearAndFree();

            try interpolateCtx(writer, person_ctx, "address.street", .Unescaped);
            try testing.expectEqualStrings("nearby", list.items);
        }

        // Address

        var address_ctx = address_ctx: {
            const path = try expectPath(allocator, "address");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path, null)) {
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

            switch (address_ctx.get(path, null)) {
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

        var person_ctx = DummyRenderEngine.getContext(&person);

        {
            list.clearAndFree();

            try interpolateCtx(writer, person_ctx, "indication.address.street", .Unescaped);
            try testing.expectEqualStrings("far away street", list.items);
        }

        // Indication

        var indication_ctx = indication_ctx: {
            const path = try expectPath(allocator, "indication");
            defer Element.destroyPath(allocator, false, path);

            switch (person_ctx.get(path, null)) {
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

            switch (indication_ctx.get(path, null)) {
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

            switch (address_ctx.get(path, null)) {
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

        var person_ctx = DummyRenderEngine.getContext(&person);

        const address_ctx = address_ctx: {
            const path = try expectPath(allocator, "address");
            defer Element.destroyPath(allocator, false, path);

            // Person.address
            switch (person_ctx.get(path, null)) {
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

            var wrong_address = person_ctx.get(path, null);
            try testing.expect(wrong_address == .not_found_in_context);
        }

        const street_ctx = street_ctx: {
            const path = try expectPath(allocator, "street");
            defer Element.destroyPath(allocator, false, path);

            // Person.address.street
            switch (address_ctx.get(path, null)) {
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

            var wrong_street = address_ctx.get(path, null);
            try testing.expect(wrong_street == .not_found_in_context);
        }

        {
            const path = try expectPath(allocator, "len");
            defer Element.destroyPath(allocator, false, path);
            // Person.address.street.len
            var street_len_ctx = switch (street_ctx.get(path, null)) {
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

            var wrong_len = street_ctx.get(path, null);
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
        var ctx = DummyRenderEngine.getContext(&person);

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

        var ctx = DummyRenderEngine.getContext(&person);

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

        var ctx = DummyRenderEngine.getContext(&person);

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
