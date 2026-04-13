const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;
const assert = std.debug.assert;

const stdx = @import("../../../stdx.zig");

const mustache = @import("../../../mustache.zig");
const Element = mustache.Element;
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;

const context = @import("../../context.zig");
const Fields = context.Fields;
const PathResolutionType = context.PathResolutionType;
const Escape = context.Escape;
const LambdaContext = context.LambdaContext;
const ContextIteratorType = context.ContextIteratorType;

const rendering = @import("../../rendering.zig");
const map = @import("../../partials_map.zig");
const lambda = @import("lambda.zig");
const invoker = @import("invoker.zig");

/// This type is a type-erasure container
/// It is large enough to hold primitives passed by value like pointers,
/// slices, enums, integers, floats and nullables.
pub const ErasedType = struct {
    const Content = u256;

    content: Content = 0,

    pub inline fn put(data: anytype) ErasedType {
        const Data = @TypeOf(data);
        const data_size = @sizeOf(Data);

        if (comptime data_size > @sizeOf(Content)) {
            @compileError(std.fmt.comptimePrint(
                "Type {s} size {} exceeds the maxinum by-val size of {}",
                .{
                    @typeName(Data),
                    data_size,
                    @sizeOf(Content),
                },
            ));
        }

        var value: ErasedType = .{};
        if (comptime data_size > 0) {
            // No need for cast checks here
            // We can assure that this pointer will always be the correct type,
            // since the context holds the type into the concrete implementation.
            @setRuntimeSafety(false);

            const ptr: *Data = @ptrCast(@alignCast(&value.content));
            ptr.* = data;
        }

        return value;
    }

    pub inline fn get(self: *const ErasedType, comptime Data: type) Data {
        const data_size = @sizeOf(Data);

        if (comptime data_size == 0) {
            return undefined;
        } else {
            // No need for cast checks here
            // We can assure that this pointer will always be the correct type,
            // since the context holds the type into the concrete implementation
            @setRuntimeSafety(false);

            const ptr = @as(*const Data, @ptrCast(@alignCast(&self.content)));
            return ptr.*;
        }
    }
};

/// Native context can resolve paths for zig structs and values
/// This struct implements the expected context interface using dynamic dispatch.
/// Pub functions must be kept in sync with other contexts implementation
pub fn ContextInterfaceType(
    comptime PartialsMap: type,
    comptime options: RenderOptions,
) type {
    const RenderEngine = rendering.RenderEngineType(.native, PartialsMap, options);
    const Writer = RenderEngine.Writer;
    const DataRender = RenderEngine.DataRender;

    return struct {
        const ContextInterface = @This();

        pub const ContextStack = struct {
            parent: ?*const @This(),
            ctx: ContextInterface,
        };

        const VTable = struct {
            get: *const fn (
                *const ErasedType,
                Element.Path,
                ?usize,
            ) PathResolutionType(ContextInterface),
            capacityHint: *const fn (
                *const ErasedType,
                *DataRender,
                Element.Path,
            ) PathResolutionType(usize),
            interpolate: *const fn (
                *const ErasedType,
                *DataRender,
                Element.Path,
                Escape,
            ) (Allocator.Error || Writer.Error)!PathResolutionType(void),
            expandLambda: *const fn (
                *const ErasedType,
                *DataRender,
                Element.Path,
                []const u8,
                Escape,
                Delimiters,
            ) (Allocator.Error || Writer.Error)!PathResolutionType(void),
        };

        pub const ContextIterator = ContextIteratorType(ContextInterface);

        ctx: ErasedType = undefined,
        vtable: *const VTable,

        pub inline fn get(
            self: ContextInterface,
            path: Element.Path,
            index: ?usize,
        ) PathResolutionType(ContextInterface) {
            return self.vtable.get(&self.ctx, path, index);
        }

        pub inline fn capacityHint(
            self: ContextInterface,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolutionType(usize) {
            return self.vtable.capacityHint(&self.ctx, data_render, path);
        }

        pub fn iterator(
            self: *const ContextInterface,
            path: Element.Path,
        ) PathResolutionType(ContextIterator) {
            const result = self.vtable.get(&self.ctx, path, 0);

            return switch (result) {
                .field => |item| .{
                    .field = ContextIterator.initSequence(self, path, item),
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

        pub inline fn interpolate(
            self: ContextInterface,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            return try self.vtable.interpolate(&self.ctx, data_render, path, escape);
        }

        pub inline fn expandLambda(
            self: ContextInterface,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            return try self.vtable.expandLambda(
                &self.ctx,
                data_render,
                path,
                inner_text,
                escape,
                delimiters,
            );
        }
    };
}

/// Implements the ContextInterface.VTable for the comptime-known data type.
pub fn ContextImplType(
    comptime Data: type,
    comptime PartialsMap: type,
    comptime options: RenderOptions,
) type {
    const RenderEngine = rendering.RenderEngineType(
        .native,
        PartialsMap,
        options,
    );
    const Writer = RenderEngine.Writer;
    const Context = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;
    const Invoker = invoker.InvokerType(PartialsMap, options);

    return struct {
        const is_zero_size = @sizeOf(Data) == 0;
        const vtable = Context.VTable{
            .get = get,
            .capacityHint = capacityHint,
            .interpolate = interpolate,
            .expandLambda = expandLambda,
        };

        pub fn ContextType(data: Data) Context {
            return .{
                .vtable = &vtable,
                .ctx = ErasedType.put(data),
            };
        }

        fn get(
            ctx: *const ErasedType,
            path: Element.Path,
            index: ?usize,
        ) PathResolutionType(Context) {
            return Invoker.get(
                ctx.get(Data),
                path,
                index,
            );
        }

        fn capacityHint(
            ctx: *const ErasedType,
            data_render: *DataRender,
            path: Element.Path,
        ) PathResolutionType(usize) {
            return Invoker.capacityHint(
                data_render,
                ctx.get(Data),
                path,
            );
        }

        fn interpolate(
            ctx: *const ErasedType,
            data_render: *DataRender,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            return Invoker.interpolate(
                data_render,
                ctx.get(Data),
                path,
                escape,
            );
        }

        fn expandLambda(
            ctx: *const ErasedType,
            data_render: *DataRender,
            path: Element.Path,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            return Invoker.expandLambda(
                data_render,
                ctx.get(Data),
                inner_text,
                escape,
                delimiters,
                path,
            );
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
        const person_1 = testing.allocator.create(Person) catch unreachable;
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

        const person_2 = Person{
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
    const DummyPartialsMap = map.PartialsMapType(void, dummy_options);
    const DummyRenderEngine = rendering.RenderEngineType(.native, DummyPartialsMap, dummy_options);

    const parsing = @import("../../../parsing/parser.zig");
    const DummyParser = parsing.ParserType(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
    const dummy_map = DummyPartialsMap.init(undefined, {});

    fn expectPath(allocator: Allocator, path: []const u8) !Element.Path {
        var parser = try DummyParser.init(allocator, "", .{});
        defer parser.deinit();

        return try parser.parsePath(path);
    }

    fn interpolate(writer: *std.Io.Writer, data: anytype, path: []const u8) anyerror!void {
        const Data = @TypeOf(data);
        const by_value = comptime Fields.byValue(Data);

        const ctx = DummyRenderEngine.getContextType(if (by_value) data else @as(*const Data, &data));

        try interpolateCtx(writer, ctx, path, .unescaped);
    }

    fn interpolateCtx(writer: *std.Io.Writer, ctx: DummyRenderEngine.Context, identifier: []const u8, escape: Escape) anyerror!void {
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

    test "Write Int" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "id");
        try testing.expectEqualStrings("2", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "id");
        try testing.expectEqualStrings("2", aw.written());

        aw.clearRetainingCapacity();

        // Nested access
        try interpolate(writer, person, "address.zip");
        try testing.expectEqualStrings("333900", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.zip");
        try testing.expectEqualStrings("99450", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, &person, "address.zip");
        try testing.expectEqualStrings("333900", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.zip");
        try testing.expectEqualStrings("99450", aw.written());
    }

    test "Write Float" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "salary");
        try testing.expectEqualStrings("140", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "salary");
        try testing.expectEqualStrings("140", aw.written());

        aw.clearRetainingCapacity();

        // Nested access
        try interpolate(writer, person, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", aw.written());

        aw.clearRetainingCapacity();

        // Negative values
        try interpolate(writer, person, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, &person, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", aw.written());

        aw.clearRetainingCapacity();

        // Negative Ref values
        try interpolate(writer, &person, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", aw.written());
    }

    test "Write String" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "name");
        try testing.expectEqualStrings("Someone Jr", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "name");
        try testing.expectEqualStrings("Someone Jr", aw.written());

        aw.clearRetainingCapacity();

        // Direct Len access
        try interpolate(writer, person, "name.len");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Direct Ref Len access
        try interpolate(writer, &person, "name.len");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Nested access
        try interpolate(writer, person, "address.street");
        try testing.expectEqualStrings("nearby", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.street");
        try testing.expectEqualStrings("far away street", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, &person, "address.street");
        try testing.expectEqualStrings("nearby", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, &person, "indication.address.street");
        try testing.expectEqualStrings("far away street", aw.written());
    }

    test "Write Enum" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "address.region");
        try testing.expectEqualStrings("RoW", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "address.region");
        try testing.expectEqualStrings("RoW", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.address.region");
        try testing.expectEqualStrings("EU", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.address.region");
        try testing.expectEqualStrings("EU", aw.written());
    }

    test "Write Bool" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "active");
        try testing.expectEqualStrings("true", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "active");
        try testing.expectEqualStrings("true", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.active");
        try testing.expectEqualStrings("false", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.active");
        try testing.expectEqualStrings("false", aw.written());
    }

    test "Write Nullable" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "additional_information");
        try testing.expectEqualStrings("someone was here", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "additional_information");
        try testing.expectEqualStrings("someone was here", aw.written());

        aw.clearRetainingCapacity();

        // Null Accress
        try interpolate(writer, person.indication, "additional_information");
        try testing.expectEqualStrings("", aw.written());

        aw.clearRetainingCapacity();

        // Null Ref Accress
        try interpolate(writer, person.indication, "additional_information");
        try testing.expectEqualStrings("", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.additional_information");
        try testing.expectEqualStrings("", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.additional_information");
        try testing.expectEqualStrings("", aw.written());
    }

    test "Write Not found" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "wrong_name");
        try testing.expectEqualStrings("", aw.written());

        // Nested access
        try interpolate(writer, person, "name.wrong_name");
        try testing.expectEqualStrings("", aw.written());

        // Direct Ref access
        try interpolate(writer, &person, "wrong_name");
        try testing.expectEqualStrings("", aw.written());

        // Nested Ref access
        try interpolate(writer, &person, "name.wrong_name");
        try testing.expectEqualStrings("", aw.written());
    }

    test "Lambda - staticLambda" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "staticLambda");
        try testing.expectEqualStrings("1", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "staticLambda");
        try testing.expectEqualStrings("1", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.staticLambda");
        try testing.expectEqualStrings("1", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, &person, "staticLambda");
        try testing.expectEqualStrings("1", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.staticLambda");
        try testing.expectEqualStrings("1", aw.written());

        aw.clearRetainingCapacity();
    }

    test "Lambda - selfLambda" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "selfLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Ref access
        try interpolate(writer, &person, "selfLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.selfLambda");
        try testing.expectEqualStrings("8", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, &person, "selfLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref pointer access
        try interpolate(writer, &person, "indication.selfLambda");
        try testing.expectEqualStrings("8", aw.written());

        aw.clearRetainingCapacity();
    }

    test "Lambda - selfConstPtrLambda" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const person_const_ptr: *const Person = &person;
        const person_ptr: *Person = &person;

        const writer = &aw.writer;

        // Direct access
        try interpolate(writer, person, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Const Ref access

        try interpolate(writer, person_const_ptr, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Mut Ref access
        try interpolate(writer, person_ptr, "selfConstPtrLambda");
        try testing.expectEqualStrings("10", aw.written());

        aw.clearRetainingCapacity();

        // Nested pointer access
        try interpolate(writer, person, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", aw.written());

        aw.clearRetainingCapacity();

        // Nested const Ref access
        try interpolate(writer, person_const_ptr, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", aw.written());

        aw.clearRetainingCapacity();

        // Nested Ref access
        try interpolate(writer, person_ptr, "indication.selfConstPtrLambda");
        try testing.expectEqualStrings("8", aw.written());

        aw.clearRetainingCapacity();
    }

    test "Lambda - Write selfMutPtrLambda" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const writer = &aw.writer;

        {
            const person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Cannot be called from a context by value
            try interpolate(writer, person, "selfMutPtrLambda");
            try testing.expectEqualStrings("", aw.written());

            aw.clearRetainingCapacity();

            // Mutable pointer
            try interpolate(writer, person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("1", aw.written());
            try testing.expect(person.indication.?.counter == 1);

            aw.clearRetainingCapacity();

            try interpolate(writer, person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("2", aw.written()); // Called again, it's mutable
            try testing.expect(person.indication.?.counter == 2);

            aw.clearRetainingCapacity();
        }

        {
            var person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Cannot be called from a context const
            const const_person_ptr: *const Person = &person;
            try interpolate(writer, const_person_ptr, "selfMutPtrLambda");
            try testing.expectEqualStrings("", aw.written());

            aw.clearRetainingCapacity();
        }

        {
            var person = getPerson();
            defer if (person.indication) |indication| allocator.destroy(indication);

            // Ref access
            try interpolate(writer, &person, "selfMutPtrLambda");
            try testing.expectEqualStrings("1", aw.written());
            try testing.expect(person.counter == 1);

            aw.clearRetainingCapacity();

            try interpolate(writer, &person, "selfMutPtrLambda");
            try testing.expectEqualStrings("2", aw.written()); //Called again, it's mutable
            try testing.expect(person.counter == 2);

            aw.clearRetainingCapacity();

            // Nested pointer access
            try interpolate(writer, &person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("1", aw.written());
            try testing.expect(person.indication.?.counter == 1);

            aw.clearRetainingCapacity();

            try interpolate(writer, &person, "indication.selfMutPtrLambda");
            try testing.expectEqualStrings("2", aw.written()); // Called again, it's mutable
            try testing.expect(person.indication.?.counter == 2);

            aw.clearRetainingCapacity();
        }
    }

    test "Lambda - error handling" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        try interpolate(writer, person, "willFailStaticLambda");
        try testing.expectEqualStrings("", aw.written());

        aw.clearRetainingCapacity();

        try interpolate(writer, person, "willFailSelfLambda");
        try testing.expectEqualStrings("unfinished", aw.written());

        aw.clearRetainingCapacity();
    }

    test "Lambda - Write invalid functions" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Unexpected arguments
        try interpolate(writer, person, "anythingElse");
        try testing.expectEqualStrings("", aw.written());

        aw.clearRetainingCapacity();
    }

    test "Navigation" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Person

        var person_ctx = DummyRenderEngine.getContextType(&person);

        {
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, person_ctx, "address.street", .unescaped);
            try testing.expectEqualStrings("nearby", aw.written());
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
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, address_ctx, "street", .unescaped);
            try testing.expectEqualStrings("nearby", aw.written());
        }

        // Street

        const street_ctx = street_ctx: {
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
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, street_ctx, "", .unescaped);
            try testing.expectEqualStrings("nearby", aw.written());
        }

        {
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, street_ctx, ".", .unescaped);
            try testing.expectEqualStrings("nearby", aw.written());
        }
    }

    test "Navigation Pointers" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Person

        var person_ctx = DummyRenderEngine.getContextType(&person);

        {
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, person_ctx, "indication.address.street", .unescaped);
            try testing.expectEqualStrings("far away street", aw.written());
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
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, indication_ctx, "address.street", .unescaped);
            try testing.expectEqualStrings("far away street", aw.written());
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
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, address_ctx, "street", .unescaped);
            try testing.expectEqualStrings("far away street", aw.written());
        }

        // Street

        const street_ctx = street_ctx: {
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
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, street_ctx, "", .unescaped);
            try testing.expectEqualStrings("far away street", aw.written());
        }

        {
            aw.clearRetainingCapacity();

            try interpolateCtx(writer, street_ctx, ".", .unescaped);
            try testing.expectEqualStrings("far away street", aw.written());
        }
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var person_ctx = DummyRenderEngine.getContextType(&person);

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

            const wrong_address = person_ctx.get(path, null);
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

            const wrong_street = address_ctx.get(path, null);
            try testing.expect(wrong_street == .not_found_in_context);
        }

        {
            const path = try expectPath(allocator, "len");
            defer Element.destroyPath(allocator, false, path);
            // Person.address.street.len
            const street_len_ctx = switch (street_ctx.get(path, null)) {
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

            const wrong_len = street_ctx.get(path, null);
            try testing.expect(wrong_len == .not_found_in_context);
        }
    }

    test "Iterator over slice" {
        const allocator = testing.allocator;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        const writer = &aw.writer;

        // Person
        var ctx = DummyRenderEngine.getContextType(&person);

        const path = try expectPath(allocator, "items");
        defer Element.destroyPath(allocator, false, path);

        var iterator = switch (ctx.iterator(path)) {
            .field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        const item_1 = iterator.next() orelse {
            try testing.expect(false);
            unreachable;
        };

        aw.clearRetainingCapacity();

        try interpolateCtx(writer, item_1, "name", .unescaped);
        try testing.expectEqualStrings("item 1", aw.written());

        const item_2 = iterator.next() orelse {
            try testing.expect(false);
            unreachable;
        };

        aw.clearRetainingCapacity();

        try interpolateCtx(writer, item_2, "name", .unescaped);
        try testing.expectEqualStrings("item 2", aw.written());

        const no_more = iterator.next();
        try testing.expect(no_more == null);
    }

    test "Iterator over bool" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var ctx = DummyRenderEngine.getContextType(&person);

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

            const item_1 = iterator.next();
            try testing.expect(item_1 != null);

            const no_more = iterator.next();
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

            const no_more = iterator.next();
            try testing.expect(no_more == null);
        }
    }

    test "Iterator over null" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var ctx = DummyRenderEngine.getContextType(&person);

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

            const item_1 = iterator.next();
            try testing.expect(item_1 != null);

            const no_more = iterator.next();
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

            const no_more = iterator.next();
            try testing.expect(no_more == null);
        }
    }
};
