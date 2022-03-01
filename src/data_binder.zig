const std = @import("std");
const TypeInfo = std.builtin.TypeInfo;

pub fn write(out_writer: anytype, data: anytype, path: []const u8) anyerror!void {
    const Binder = DataBinder(@TypeOf(data));

    const PATH_SEPARATOR = ".";
    var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
    try Binder.write(out_writer, data, &path_iterator);
}

fn DataBinder(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn write(out_writer: anytype, data: T, path_iterator: *std.mem.TokenIterator(u8)) anyerror!void {
            if (path_iterator.next()) |token| {
                try recursiveWrite(T, out_writer, data, token, path_iterator);
            } else {
                try stringify(out_writer, data);
            }
        }

        fn recursiveWrite(comptime TValue: type, out_writer: anytype, data: anytype, path: []const u8, path_iterator: *std.mem.TokenIterator(u8)) anyerror!void {
            const typeInfo = @typeInfo(TValue);

            switch (typeInfo) {
                .Struct => try writeField(TValue, out_writer, data, path, path_iterator),
                .Pointer => |info| switch (info.size) {
                    TypeInfo.Pointer.Size.One => try recursiveWrite(info.child, out_writer, data, path, path_iterator),
                    TypeInfo.Pointer.Size.Slice => {

                        //Slice supports the "len" field,
                        if (std.mem.eql(u8, "len", path)) {
                            const Binder = DataBinder(@TypeOf(data.len));
                            try Binder.write(out_writer, data.len, path_iterator);
                        }
                    },

                    TypeInfo.Pointer.Size.Many => @compileError("[*] pointers not supported"),
                    TypeInfo.Pointer.Size.C => @compileError("[*c] pointers not supported"),
                },
                .Optional => |info| {
                    if (data) |value| {
                        try recursiveWrite(info.child, out_writer, value, path, path_iterator);
                    } else {
                        //EMPTY
                        return;
                    }
                },
                else => {},
            }
        }

        fn writeField(comptime TValue: type, out_writer: anytype, data: anytype, path: []const u8, path_iterator: *std.mem.TokenIterator(u8)) anyerror!void {
            const fields = std.meta.fields(TValue);
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, path)) {
                    const Binder = DataBinder(field.field_type);
                    return try Binder.write(out_writer, @field(data, field.name), path_iterator);
                }
            }

            return;
        }

        fn stringify(out_writer: anytype, value: anytype) anyerror!void {
            const typeInfo = @typeInfo(@TypeOf(value));

            switch (typeInfo) {
                .Struct, .Opaque => try std.fmt.format(out_writer, "{?}", .{value}),

                // primitives has no field access
                .Bool => try out_writer.writeAll(if (value) "true" else "false"),

                .Int, .ComptimeInt => try std.fmt.formatInt(value, 10, .lower, .{}, out_writer),

                .Float, .ComptimeFloat => try std.fmt.formatFloatDecimal(value, .{}, out_writer),

                .Enum => try out_writer.writeAll(@tagName(value)),

                .Pointer => |info| switch (info.size) {
                    TypeInfo.Pointer.Size.One => try stringify(out_writer, value.*),
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
                        try stringify(out_writer, not_null);
                    }
                },
                else => @compileError("Not supported"),
            }
        }
    };
}

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

    test "Int" {
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

    test "Float" {
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

    test "String" {
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

    test "Enum" {
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

    test "Bool" {
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

    test "Nullable" {
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

    test "Not found" {
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
};
