const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;

const lambda = @import("lambda.zig");
const LambdaContext = lambda.LambdaContext;

const invoker = @import("invoker.zig");

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

pub fn getContext(allocator: Allocator, out_writer: anytype, data: anytype) Allocator.Error!Context(@TypeOf(out_writer)) {
    const Impl = ContextImpl(@TypeOf(out_writer), @TypeOf(data));
    return try Impl.init(allocator, out_writer, data);
}

pub fn Context(comptime Writer: type) type {
    return struct {
        const Self = @This();

        pub const ContextStack = struct {
            parent: ?*@This(),
            ctx: Self,
        };

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            get: fn (*anyopaque, Allocator, []const u8, ?usize) Allocator.Error!PathResolution(Self),
            interpolate: fn (*anyopaque, []const u8, Escape) Writer.Error!PathResolution(void),
            expandLambda: fn (*anyopaque, Allocator, *const ContextStack, []const u8, []const u8, Escape) (Allocator.Error || Writer.Error)!PathResolution(void),
            check: fn (*anyopaque, []const u8, usize) PathResolution(void),
            deinit: fn (*anyopaque, Allocator) void,
        };

        pub const Iterator = struct {
            context: *const Self,
            path: []const u8,
            current: usize,
            finished: bool,
            is_lambda: bool,

            pub fn hasNext(self: Iterator) bool {
                if (self.finished) {
                    return false;
                } else {
                    const result = self.context.vtable.check(
                        self.context.ptr,
                        self.path,
                        self.current,
                    );

                    return switch (result) {
                        .Field => true,
                        .IteratorConsumed => false,
                        else => {
                            assert(false);
                            unreachable;
                        },
                    };
                }
            }

            pub fn next(self: *Iterator, allocator: Allocator) Allocator.Error!?Self {
                if (self.finished) {
                    return null;
                } else {
                    defer self.current += 1;
                    const result = try self.context.vtable.get(
                        self.context.ptr,
                        allocator,
                        self.path,
                        self.current,
                    );

                    // Keeping the iterator pattern
                    switch (result) {
                        .Field => |found| return found,
                        .IteratorConsumed => {
                            self.finished = true;
                            return null;
                        },
                        else => {
                            assert(false);
                            unreachable;
                        },
                    }
                }
            }
        };

        pub inline fn get(self: Self, allocator: Allocator, path: []const u8) Allocator.Error!PathResolution(Self) {
            return try self.vtable.get(self.ptr, allocator, path, null);
        }

        pub fn iterator(self: *const Self, path: []const u8) PathResolution(Iterator) {
            const result = self.vtable.check(self.ptr, path, 0);

            return switch (result) {
                .Field,
                .IteratorConsumed,
                => .{
                    .Field = .{
                        .context = self,
                        .path = path,
                        .current = 0,
                        .finished = result == .IteratorConsumed,
                        .is_lambda = false,
                    },
                },
                .Lambda => .{
                    .Lambda = .{
                        .context = self,
                        .path = path,
                        .current = 0,
                        .finished = true,
                        .is_lambda = true,
                    },
                },

                .ChainBroken => .ChainBroken,
                .NotFoundInContext => .NotFoundInContext,
            };
        }

        pub inline fn interpolate(self: Self, path: []const u8, escape: Escape) Writer.Error!PathResolution(void) {
            return try self.vtable.interpolate(self.ptr, path, escape);
        }

        pub inline fn expandLambda(self: Self, allocator: Allocator, stack: *const ContextStack, path: []const u8, inner_text: []const u8, escape: Escape) (Allocator.Error || Writer.Error)!PathResolution(void) {
            return try self.vtable.expandLambda(self.ptr, allocator, stack, path, inner_text, escape);
        }

        pub inline fn deinit(self: Self, allocator: Allocator) void {
            return self.vtable.deinit(self.ptr, allocator);
        }
    };
}

fn ContextImpl(comptime Writer: type, comptime Data: type) type {
    return struct {
        const ContextInterface = Context(Writer);
        const ContextStack = ContextInterface.ContextStack;

        const vtable = ContextInterface.VTable{
            .get = get,
            .check = check,
            .interpolate = interpolate,
            .expandLambda = expandLambda,
            .deinit = deinit,
        };

        const PATH_SEPARATOR = ".";
        const Self = @This();

        // If a NullWriter is used with and a zero size Data, we cannot create an pointer
        // Compiler error: '*Self' and '*anyopaque' do not have the same in-memory representation
        // note: '*Self" has no in-memory bits
        // note: '*anyopaque' has in-memory bits
        const is_zero_size = @sizeOf(Writer) + @sizeOf(Data) == 0;

        writer: Writer,
        data: Data,

        pub fn init(allocator: Allocator, writer: Writer, data: Data) Allocator.Error!ContextInterface {
            return ContextInterface{
                .ptr = if (is_zero_size) undefined else blk: {
                    var self = try allocator.create(Self);
                    self.* = .{
                        .writer = writer,
                        .data = data,
                    };

                    break :blk self;
                },
                .vtable = &vtable,
            };
        }

        fn get(ctx: *anyopaque, allocator: Allocator, path: []const u8, index: ?usize) Allocator.Error!PathResolution(ContextInterface) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try invoker.get(allocator, self.writer, self.data, &path_iterator, index);
        }

        fn check(ctx: *anyopaque, path: []const u8, index: usize) PathResolution(void) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return invoker.check(self.data, &path_iterator, index);
        }

        fn interpolate(ctx: *anyopaque, path: []const u8, escape: Escape) Writer.Error!PathResolution(void) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try invoker.interpolate(self.writer, self.data, &path_iterator, escape);
        }

        fn expandLambda(ctx: *anyopaque, allocator: Allocator, stack: *const ContextStack, path: []const u8, inner_text: []const u8, escape: Escape) (Allocator.Error || Writer.Error)!PathResolution(void) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);

            return try invoker.expandLambda(
                allocator,
                self.writer,
                self.data,
                stack,
                inner_text,
                escape,
                &path_iterator,
            );
        }

        fn deinit(ctx: *anyopaque, allocator: Allocator) void {
            if (!is_zero_size) {
                var self = getSelf(ctx);
                allocator.destroy(self);
            }
        }

        inline fn getSelf(ctx: *anyopaque) *Self {
            return if (is_zero_size) undefined else @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
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
            const str = try std.fmt.allocPrint(ctx.allocator, "{}", .{self.name.len});
            defer ctx.allocator.free(str);
            return try ctx.write(str);
        }

        pub fn selfConstPtrLambda(self: *const Person, ctx: LambdaContext) !void {
            const str = try std.fmt.allocPrint(ctx.allocator, "{}", .{self.name.len});
            defer ctx.allocator.free(str);

            return try ctx.write(str);
        }

        pub fn selfMutPtrLambda(self: *Person, ctx: LambdaContext) !void {
            self.counter += 1;

            const str = try std.fmt.allocPrint(ctx.allocator, "{}", .{self.counter});
            defer ctx.allocator.free(str);
            return try ctx.write(str);
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

    fn interpolate(out_writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const allocator = testing.allocator;

        var ctx = try getContext(allocator, out_writer, data);
        defer ctx.deinit(allocator);

        switch (try ctx.interpolate(path, .Unescaped)) {
            .Lambda => {
                var stack = @TypeOf(ctx).ContextStack{
                    .parent = null,
                    .ctx = ctx,
                };

                _ = try ctx.expandLambda(allocator, &stack, path, "", .Unescaped);
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

        var person_ctx = try getContext(allocator, writer, person);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.interpolate("address.street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Address

        var address_ctx = switch (try person_ctx.get(allocator, "address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.interpolate("street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Street

        var street_ctx = switch (try address_ctx.get(allocator, "street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.interpolate("", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        _ = try street_ctx.interpolate(".", .Unescaped);
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

        var person_ctx = try getContext(allocator, writer, &person);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.interpolate("indication.address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Indication

        var indication_ctx = switch (try person_ctx.get(allocator, "indication")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer indication_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try indication_ctx.interpolate("address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Address

        var address_ctx = switch (try indication_ctx.get(allocator, "address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.interpolate("street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Street

        var street_ctx = switch (try address_ctx.get(allocator, "street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.interpolate("", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        _ = try street_ctx.interpolate(".", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var person_ctx = try getContext(allocator, std.io.null_writer, person);
        defer person_ctx.deinit(allocator);

        // Person.address
        var address_ctx = switch (try person_ctx.get(allocator, "address")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer address_ctx.deinit(allocator);

        var wrong_address = try person_ctx.get(allocator, "wrong_address");
        try testing.expect(wrong_address == .NotFoundInContext);

        // Person.address.street
        var street_ctx = switch (try address_ctx.get(allocator, "street")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_ctx.deinit(allocator);

        var wrong_street = try address_ctx.get(allocator, "wrong_street");
        try testing.expect(wrong_street == .NotFoundInContext);

        // Person.address.street.len
        var street_len_ctx = switch (try street_ctx.get(allocator, "len")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_len_ctx.deinit(allocator);

        var wrong_len = try street_ctx.get(allocator, "wrong_len");
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
        var ctx = try getContext(allocator, writer, person);
        defer ctx.deinit(allocator);

        var iterator = switch (ctx.iterator("items")) {
            .Field => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };

        var item_1 = (try iterator.next(allocator)) orelse {
            try testing.expect(false);
            return;
        };
        defer item_1.deinit(allocator);

        list.clearAndFree();

        _ = try item_1.interpolate("name", .Unescaped);
        try testing.expectEqualStrings("item 1", list.items);

        var item_2 = (try iterator.next(allocator)) orelse {
            try testing.expect(false);
            return;
        };
        defer item_2.deinit(allocator);

        list.clearAndFree();

        _ = try item_2.interpolate("name", .Unescaped);
        try testing.expectEqualStrings("item 2", list.items);

        var no_more = try iterator.next(allocator);
        try testing.expect(no_more == null);
    }

    test "Iterator over bool" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var ctx = try getContext(allocator, std.io.null_writer, person);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = switch (ctx.iterator("active")) {
                .Field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var item_1 = (try iterator.next(allocator)) orelse {
                try testing.expect(false);
                return;
            };
            defer item_1.deinit(allocator);

            var no_more = try iterator.next(allocator);
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

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }
    }

    test "Iterator over null" {
        const allocator = testing.allocator;

        // Person
        var person = getPerson();
        defer if (person.indication) |indication| allocator.destroy(indication);

        var ctx = try getContext(allocator, std.io.null_writer, person);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = switch (ctx.iterator("additional_information")) {
                .Field => |found| found,
                else => {
                    try testing.expect(false);
                    unreachable;
                },
            };

            var item_1 = (try iterator.next(allocator)) orelse {
                try testing.expect(false);
                return;
            };
            defer item_1.deinit(allocator);

            var no_more = try iterator.next(allocator);
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

            var no_more = try iterator.next(allocator);
            try testing.expect(no_more == null);
        }
    }
};
