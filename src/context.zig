const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeInfo = std.builtin.TypeInfo;

pub const Context = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: fn (ctx: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?Context,
        write: fn (ctx: *anyopaque, path: []const u8) anyerror!bool,
        deinit: fn (ctx: *anyopaque, allocator: Allocator) void,
    };

    pub inline fn get(self: Context, allocator: Allocator, path: []const u8) anyerror!?Context {
        return try self.vtable.get(self.ptr, allocator, path);
    }

    pub inline fn write(self: Context, path: []const u8) anyerror!bool {
        return try self.vtable.write(self.ptr, path);
    }

    pub inline fn deinit(self: Context, allocator: Allocator) void {
        return self.vtable.deinit(self.ptr, allocator);
    }
};

pub fn getContext(allocator: Allocator, out_writer: anytype, data: anytype) Allocator.Error!Context {
    const Impl = ContextImpl(@TypeOf(out_writer), @TypeOf(data));
    return try Impl.init(allocator, out_writer, data);
}

fn ContextImpl(comptime Writer: type, comptime Data: type) type {
    return struct {
        const vtable = Context.VTable{
            .get = get,
            .write = write,
            .deinit = deinit,
        };

        const PATH_SEPARATOR = ".";
        const Self = @This();

        writer: Writer,
        data: Data,

        pub fn init(allocator: Allocator, writer: Writer, data: Data) Allocator.Error!Context {
            var self = try allocator.create(Self);
            self.* = .{
                .writer = writer,
                .data = data,
            };

            return Context{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        fn get(ctx: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?Context {
            var self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            try return Functions.get(allocator, self.writer, self.data, &path_iterator);
        }

        fn write(ctx: *anyopaque, path: []const u8) anyerror!bool {
            var self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            try Functions.write(self.writer, self.data, &path_iterator);
            return true;
        }

        fn deinit(ctx: *anyopaque, allocator: Allocator) void {
            var self = @ptrCast(*Self, @alignCast(@alignOf(Self), ctx));
            allocator.destroy(self);
        }
    };
}

const Functions = struct {
    pub fn get(allocator: Allocator, out_writer: anytype, data: anytype, path_iterator: *std.mem.TokenIterator(u8)) anyerror!?Context {
        return try seek(Context, getContext, allocator, out_writer, data, path_iterator);
    }

    pub fn write(out_writer: anytype, data: anytype, path_iterator: *std.mem.TokenIterator(u8)) anyerror!void {
        _ = try seek(void, stringify, {}, out_writer, data, path_iterator);
    }

    fn seek(
        comptime TReturn: type,
        action: anytype,
        allocator: anytype,
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
    ) anyerror!?TReturn {
        if (path_iterator.next()) |token| {
            return try recursiveSeek(TReturn, @TypeOf(data), action, allocator, out_writer, data, token, path_iterator);
        } else {
            return try action(allocator, out_writer, data);
        }
    }

    fn recursiveSeek(
        comptime TReturn: type,
        comptime TValue: type,
        action: anytype,
        allocator: anytype,
        out_writer: anytype,
        data: anytype,
        path: []const u8,
        path_iterator: *std.mem.TokenIterator(u8),
    ) anyerror!?TReturn {
        const typeInfo = @typeInfo(TValue);

        switch (typeInfo) {
            .Struct => return try seekField(TReturn, TValue, action, allocator, out_writer, data, path, path_iterator),
            .Pointer => |info| switch (info.size) {
                TypeInfo.Pointer.Size.One => return try recursiveSeek(TReturn, info.child, action, allocator, out_writer, data, path, path_iterator),
                TypeInfo.Pointer.Size.Slice => {

                    //Slice supports the "len" field,
                    if (std.mem.eql(u8, "len", path)) {
                        try return seek(TReturn, action, allocator, out_writer, data.len, path_iterator);
                    }
                },

                TypeInfo.Pointer.Size.Many => @compileError("[*] pointers not supported"),
                TypeInfo.Pointer.Size.C => @compileError("[*c] pointers not supported"),
            },
            .Optional => |info| {
                if (data) |value| {
                    return try return recursiveSeek(TReturn, info.child, action, allocator, out_writer, value, path, path_iterator);
                }
            },
            else => {},
        }

        return null;
    }

    fn seekField(
        comptime TReturn: type,
        comptime TValue: type,
        action: anytype,
        allocator: anytype,
        out_writer: anytype,
        data: anytype,
        path: []const u8,
        path_iterator: *std.mem.TokenIterator(u8),
    ) anyerror!?TReturn {
        const fields = std.meta.fields(TValue);
        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, path)) {
                return try seek(TReturn, action, allocator, out_writer, @field(data, field.name), path_iterator);
            }
        }

        return null;
    }

    fn stringify(allocator: void, out_writer: anytype, value: anytype) anyerror!void {
        const typeInfo = @typeInfo(@TypeOf(value));

        switch (typeInfo) {
            .Struct, .Opaque => try std.fmt.format(out_writer, "{?}", .{value}),

            // primitives has no field access
            .Bool => try out_writer.writeAll(if (value) "true" else "false"),

            .Int, .ComptimeInt => try std.fmt.formatInt(value, 10, .lower, .{}, out_writer),

            .Float, .ComptimeFloat => try std.fmt.formatFloatDecimal(value, .{}, out_writer),

            .Enum => try out_writer.writeAll(@tagName(value)),

            .Pointer => |info| switch (info.size) {
                TypeInfo.Pointer.Size.One => try stringify(allocator, out_writer, value.*),
                TypeInfo.Pointer.Size.Slice => {
                    if (info.child == u8 and std.unicode.utf8ValidateSlice(value)) {
                        try out_writer.writeAll(value);
                    }
                },
                TypeInfo.Pointer.Size.Many => @compileError("[*] pointers not supported"),
                TypeInfo.Pointer.Size.C => @compileError("[*c] pointers not supported"),
            },
            .Array => {},
            .Optional => {
                if (value) |not_null| {
                    try stringify(allocator, out_writer, not_null);
                }
            },
            else => @compileError("Not supported"),
        }
    }
};

test {
    _ = struct_tests;
}
const testing = std.testing;

const struct_tests = struct {

    // Test model
    const Person = struct {
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
        salary: f32,
        indication: ?*Person,
        active: bool,
        additional_information: ?[]const u8,
    };

    var person_1 = Person{
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
        .salary = 140.00,
        .indication = &person_1,
        .active = true,
        .additional_information = "someone was here",
    };

    fn write(out_writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const allocator = testing.allocator;

        var ctx = try getContext(allocator, out_writer, data);
        defer ctx.deinit(allocator);

        _ = try ctx.write(path);
    }

    test "Write Int" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "id");
        try testing.expectEqualStrings("2", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.zip");
        try testing.expectEqualStrings("333900", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.zip");
        try testing.expectEqualStrings("99450", list.items);
    }

    test "Write Float" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "salary");
        try testing.expectEqualStrings("140", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative values
        try write(writer, person_2, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.coordinates.lon");
        try testing.expectEqualStrings("38.71471", list.items);

        list.clearAndFree();

        // Negative Ref values
        try write(writer, &person_2, "address.coordinates.lat");
        try testing.expectEqualStrings("-9.13872", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.coordinates.lon");
        try testing.expectEqualStrings("41.40338", list.items);
    }

    test "Write String" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "name");
        try testing.expectEqualStrings("Someone Jr", list.items);

        list.clearAndFree();

        // Direct Len access
        try write(writer, person_2, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Direct Ref Len access
        try write(writer, &person_2, "name.len");
        try testing.expectEqualStrings("10", list.items);

        list.clearAndFree();

        // Nested access
        try write(writer, person_2, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        // Nested Ref access
        try write(writer, &person_2, "address.street");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, &person_2, "indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Write Enum" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "address.region");
        try testing.expectEqualStrings("RoW", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.address.region");
        try testing.expectEqualStrings("EU", list.items);
    }

    test "Write Bool" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "active");
        try testing.expectEqualStrings("true", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.active");
        try testing.expectEqualStrings("false", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.active");
        try testing.expectEqualStrings("false", list.items);
    }

    test "Write Nullable" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_2, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Ref access
        try write(writer, &person_2, "additional_information");
        try testing.expectEqualStrings("someone was here", list.items);

        list.clearAndFree();

        // Null Accress
        try write(writer, person_1, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Null Ref Accress
        try write(writer, &person_1, "additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested pointer access
        try write(writer, person_2, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);

        list.clearAndFree();

        // Nested Ref pointer access
        try write(writer, &person_2, "indication.additional_information");
        try testing.expectEqualStrings("", list.items);
    }

    test "Write Not found" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Direct access
        try write(writer, person_1, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested access
        try write(writer, person_1, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Direct Ref access
        try write(writer, &person_1, "wrong_name");
        try testing.expectEqualStrings("", list.items);

        // Nested Ref access
        try write(writer, &person_1, "name.wrong_name");
        try testing.expectEqualStrings("", list.items);
    }

    test "Navigation" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Person

        var person_ctx = try getContext(allocator, writer, person_2);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.write("address.street");
        try testing.expectEqualStrings("nearby", list.items);

        // Address

        var address_ctx = (try person_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street");
        try testing.expectEqualStrings("nearby", list.items);

        // Street

        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("");
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".");
        try testing.expectEqualStrings("nearby", list.items);
    }

    test "Navigation Pointers" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        var writer = list.writer();

        // Person

        var person_ctx = try getContext(allocator, writer, &person_2);
        defer person_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try person_ctx.write("indication.address.street");
        try testing.expectEqualStrings("far away street", list.items);

        // Indication

        var indication_ctx = (try person_ctx.get(allocator, "indication")) orelse {
            try testing.expect(false);
            return;
        };
        defer indication_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try indication_ctx.write("address.street");
        try testing.expectEqualStrings("far away street", list.items);

        // Address

        var address_ctx = (try indication_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street");
        try testing.expectEqualStrings("far away street", list.items);

        // Street

        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("");
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".");
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person_ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer person_ctx.deinit(allocator);

        // Person.address
        var address_ctx = (try person_ctx.get(allocator, "address")) orelse {
            try testing.expect(false);
            return;
        };
        defer address_ctx.deinit(allocator);

        var wrong_address = try person_ctx.get(allocator, "wrong_address");
        try testing.expect(wrong_address == null);

        // Person.address.street
        var street_ctx = (try address_ctx.get(allocator, "street")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_ctx.deinit(allocator);

        var wrong_street = try address_ctx.get(allocator, "wrong_street");
        try testing.expect(wrong_street == null);

        // Person.address.street.len
        var street_len_ctx = (try street_ctx.get(allocator, "len")) orelse {
            try testing.expect(false);
            return;
        };
        defer street_len_ctx.deinit(allocator);

        var wrong_len = try street_ctx.get(allocator, "wrong_len");
        try testing.expect(wrong_len == null);
    }
};
