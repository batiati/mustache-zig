const std = @import("std");
const meta = std.meta;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;

const context = @import("context.zig");

const lambda = @import("contexts/native/lambda.zig");
const native_context = @import("contexts/native/context.zig");
const ErasedType = native_context.ErasedType;

const extern_types = @import("../ffi/extern_types.zig");

pub inline fn getField(data: anytype, comptime field_name: []const u8) field_type: {
    const TField = FieldType(@TypeOf(data), field_name);

    if (TField == comptime_int) {
        const comptime_value = @field(data, field_name);
        break :field_type RuntimeInt(comptime_value);
    } else if (TField == comptime_float) {
        const comptime_value = @field(data, field_name);
        break :field_type RuntimeFloat(comptime_value);
    } else if (TField == @Type(.Null)) {
        break :field_type ?u0;
    } else {
        break :field_type FieldRef(@TypeOf(data), field_name);
    }
} {
    const Data = @TypeOf(data);
    const TField = FieldType(Data, field_name);

    const is_by_value = comptime byValue(TField);

    if (TField == comptime_int) {
        const comptime_value = @field(data, field_name);
        const runtime_value: RuntimeInt(comptime_value) = comptime_value;
        return runtime_value;
    } else if (TField == comptime_float) {
        const comptime_value = @field(data, field_name);
        const runtime_value: RuntimeFloat(comptime_value) = comptime_value;
        return runtime_value;
    } else if (TField == @TypeOf(.Null)) {
        const runtime_null: ?u0 = null;
        return runtime_null;
    }

    return if (is_by_value) @field(lhs(Data, data), field_name) else &@field(lhs(Data, data), field_name);
}

pub inline fn getRuntimeValue(ctx: anytype) context_type: {
    const TContext = @TypeOf(ctx);

    if (TContext == comptime_int) {
        const comptime_value = ctx;
        break :context_type RuntimeInt(comptime_value);
    } else if (TContext == comptime_float) {
        const comptime_value = ctx;
        break :context_type RuntimeFloat(comptime_value);
    } else if (TContext == @Type(.Null)) {
        break :context_type ?u0;
    } else {
        break :context_type TContext;
    }
} {
    const TContext = @TypeOf(ctx);

    if (TContext == comptime_int) {
        const comptime_value = ctx;
        const runtime_value: RuntimeInt(comptime_value) = comptime_value;
        return runtime_value;
    } else if (TContext == comptime_float) {
        const comptime_value = ctx;
        const runtime_value: RuntimeFloat(comptime_value) = comptime_value;
        return runtime_value;
    } else if (TContext == @TypeOf(.Null)) {
        const runtime_null: ?u0 = null;
        return runtime_null;
    } else {
        return ctx;
    }
}

pub inline fn getTupleElement(ctx: anytype, comptime index: usize) element_type: {
    const T = @TypeOf(ctx);
    assert(mustache.isTuple(T));

    const ElementType = @TypeOf(ctx[index]);
    if (ElementType == comptime_int) {
        const comptime_value = ctx[index];
        break :element_type RuntimeInt(comptime_value);
    } else if (ElementType == comptime_float) {
        const comptime_value = ctx[index];
        break :element_type RuntimeFloat(comptime_value);
    } else if (ElementType == @Type(.Null)) {
        break :element_type ?u0;
    } else if (byValue(ElementType)) {
        break :element_type ElementType;
    } else {
        break :element_type @TypeOf(&ctx[index]);
    }
} {
    const ElementType = @TypeOf(ctx[index]);
    if (ElementType == comptime_int) {
        const comptime_value = ctx[index];
        const runtime_value: RuntimeInt(comptime_value) = comptime_value;
        return runtime_value;
    } else if (ElementType == comptime_float) {
        const comptime_value = ctx[index];
        const runtime_value: RuntimeFloat(comptime_value) = comptime_value;
        return runtime_value;
    } else if (ElementType == @Type(.Null)) {
        const runtime_null: ?u0 = null;
        return runtime_null;
    } else if (comptime byValue(ElementType)) {
        return ctx[index];
    } else {
        return &ctx[index];
    }
}

pub inline fn getElement(ctx: anytype, index: usize) element_type: {
    const T = @TypeOf(ctx);

    const is_indexable = mustache.isIndexable(T) and !mustache.isTuple(T);
    if (!is_indexable) @compileError("Array, slice or vector expected");

    const ElementType = @TypeOf(ctx[0]);

    if (byValue(ElementType)) {
        break :element_type ElementType;
    } else {
        break :element_type @TypeOf(&ctx[0]);
    }
} {
    const ElementType = @TypeOf(ctx[0]);

    if (comptime byValue(ElementType)) {
        return ctx[index];
    } else {
        return &ctx[index];
    }
}

fn Lhs(comptime T: type) type {
    comptime {
        if (mustache.is(.Optional)(T)) {
            return Lhs(meta.Child(T));
        } else if (needsDerref(T)) {
            return Lhs(meta.Child(T));
        } else {
            return T;
        }
    }
}

pub inline fn lhs(comptime T: type, value: T) Lhs(T) {
    if (comptime mustache.is(.Optional)(T)) {
        return lhs(@TypeOf(value.?), value.?);
    } else if (comptime needsDerref(T)) {
        return lhs(@TypeOf(value.*), value.*);
    } else {
        return value;
    }
}

pub inline fn needsDerref(comptime T: type) bool {
    comptime {
        if (mustache.isSingleItemPtr(T)) {
            const Child = meta.Child(T);
            return mustache.isSingleItemPtr(Child) or mustache.isSlice(Child) or mustache.is(.Optional)(Child);
        } else {
            return false;
        }
    }
}

pub fn byValue(comptime TField: type) bool {
    comptime {
        if (mustache.is(.EnumLiteral)(TField)) @compileError(
            \\Enum literal is not supported for interpolation
            \\Error: ir_resolve_lazy_recurse. This is a bug in the Zig compiler
            \\Type:
        ++ @typeName(TField));

        const max_size = @sizeOf(ErasedType);
        const size = if (TField == @TypeOf(null)) 0 else @sizeOf(TField);
        const is_zero_size = size == 0;

        const is_pointer = mustache.isSlice(TField) or
            mustache.isSingleItemPtr(TField);

        const is_json = TField == std.json.Value;

        const is_ffi_userdata = TField == extern_types.UserData;

        const is_lambda_invoker = size <= max_size and lambda.isLambdaInvoker(TField);

        const can_embed = size <= max_size and
            (mustache.is(.Enum)(TField) or
            mustache.is(.EnumLiteral)(TField) or
            TField == bool or
            mustache.isIntegral(TField) or
            mustache.isFloat(TField) or
            (mustache.is(.Optional)(TField) and byValue(meta.Child(TField))));

        return is_json or is_ffi_userdata or is_zero_size or is_pointer or is_lambda_invoker or can_embed;
    }
}

pub inline fn isNull(comptime T: type, data: T) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .One => return isNull(@TypeOf(data.*), data.*),
            .Slice => return false,
            .Many => @compileError("[*] pointers not supported"),
            .C => @compileError("[*c] pointers not supported"),
        },
        .Optional => return data == null,
        else => return false,
    };
}

pub inline fn lenOf(comptime T: type, data: T) ?usize {
    return switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .One => return null,
            .Slice => return data.len,
            .Many => @compileError("[*] pointers not supported"),
            .C => @compileError("[*c] pointers not supported"),
        },
        .Array, .Vector => return data.len,
        .Optional => if (data) |value| return lenOf(@TypeOf(value), value) else null,
        else => return null,
    };
}

fn FieldRef(comptime T: type, comptime field_name: []const u8) type {
    comptime {
        const TField = FieldType(T, field_name);

        assert(TField != comptime_int);
        assert(TField != comptime_float);
        assert(TField != @TypeOf(.Null));

        if (mustache.is(.Optional)(T)) {
            return FieldRef(meta.Child(T), field_name);
        } else if (needsDerref(T)) {
            return FieldRef(meta.Child(T), field_name);
        } else {
            const instance: T = switch (@typeInfo(T)) {
                .Struct => std.mem.zeroInit(T, .{}),
                .Pointer => @ptrFromInt(@alignOf(T)),
                .Void => {},
                else => undefined,
            };

            return if (byValue(TField)) @TypeOf(@field(instance, field_name)) else @TypeOf(&@field(instance, field_name));
        }
    }
}

fn FieldType(comptime T: type, comptime field_name: []const u8) type {
    if (mustache.is(.Optional)(T)) {
        const Child = meta.Child(T);
        return FieldType(Child, field_name);
    } else if (mustache.isSingleItemPtr(T)) {
        const Child = meta.Child(T);
        return FieldType(Child, field_name);
    } else {
        const instance: T = undefined;
        return @TypeOf(@field(instance, field_name));
    }
}

fn RuntimeInt(comptime value: comptime_int) type {
    return if (value > 0) std.math.IntFittingRange(0, value) else std.math.IntFittingRange(value, 0);
}

fn RuntimeFloat(comptime value: comptime_float) type {
    _ = value;
    return f64;
}

test "Needs derref" {
    var value: usize = 10;
    var ptr = &value;
    const const_ptr: *const usize = &value;
    const ptr_ptr = &ptr;
    const const_ptr_ptr: *const *usize = &ptr;

    try std.testing.expect(needsDerref(@TypeOf(value)) == false);
    try std.testing.expect(needsDerref(@TypeOf(ptr)) == false);
    try std.testing.expect(needsDerref(@TypeOf((const_ptr))) == false);

    try std.testing.expect(needsDerref(@TypeOf(ptr_ptr)) == true);
    try std.testing.expect(needsDerref(@TypeOf(const_ptr_ptr)) == true);

    var optional: ?usize = value;
    try std.testing.expect(needsDerref(@TypeOf(optional)) == false);

    const ptr_optional: *?usize = &optional;
    try std.testing.expect(needsDerref(@TypeOf(ptr_optional)) == true);

    const optional_ptr: ?*usize = ptr;
    try std.testing.expect(needsDerref(@TypeOf(optional_ptr)) == false);
}

test "Ref values" {
    const Data = struct {
        int: usize,
        level: struct {
            int: usize,
        },
    };

    var data = Data{ .int = 100, .level = .{ .int = 1000 } };
    const field = getField(&data, "int");
    try std.testing.expectEqual(field, data.int);

    var level = getField(&data, "level");
    try std.testing.expectEqual(level.int, data.level.int);

    data.level.int = 1001;
    try std.testing.expectEqual(level.int, data.level.int);

    level.int = 1002;
    try std.testing.expectEqual(level.int, data.level.int);

    const level_field = getField(level, "int");
    try std.testing.expectEqual(level_field, level.int);
    try std.testing.expectEqual(level_field, data.level.int);
}

test "Const ref values" {
    var data = .{ .int = @as(usize, 100), .level = .{ .int = @as(usize, 1000) } };

    const field = getField(&data, "int");
    try std.testing.expectEqual(field, data.int);

    const level = getField(&data, "level");
    try std.testing.expectEqual(level.int, data.level.int);

    const level_field = getField(level, "int");
    try std.testing.expectEqual(level_field, data.level.int);
}

test "comptime int" {
    var data = .{ .int = 100, .level = .{ .int = 1000 } };

    const field = getField(&data, "int");
    try std.testing.expectEqual(field, data.int);

    const level = getField(&data, "level");
    try std.testing.expectEqual(level.int, data.level.int);

    const level_field = getField(level, "int");
    try std.testing.expectEqual(level_field, data.level.int);
}

test "comptime floats" {
    var data = .{ .float = 3.14, .level = .{ .float = std.math.floatMin(f128) } };

    const field = getField(&data, "float");
    try std.testing.expectEqual(field, data.float);
    try std.testing.expect(@TypeOf(field) == f64);

    const level = getField(&data, "level");
    try std.testing.expectEqual(level.float, data.level.float);

    const level_field = getField(level, "float");
    try std.testing.expectEqual(level_field, data.level.float);
    try std.testing.expect(@TypeOf(level_field) == f128);
}

test "enum literal " {

    // Skip
    // ir_resolve_lazy_recurse. This is a bug in the Zig compiler
    if (true) return error.SkipZigTest;

    var data = .{ .value = .AreYouSure, .level = .{ .value = .Totally } };

    const field = getField(&data, "value");
    try std.testing.expectEqual(field, data.value);

    const level = getField(&data, "level");
    try std.testing.expectEqual(level.value, data.level.int);

    const level_field = getField(level, "value");
    try std.testing.expectEqual(level_field, data.level.int);
}

test "enum" {
    const Options = enum { AreYouSure, Totally };
    var data = .{ .value = Options.AreYouSure, .level = .{ .value = Options.Totally } };

    const field = getField(&data, "value");
    try std.testing.expectEqual(field, data.value);

    const level = getField(&data, "level");
    try std.testing.expectEqual(level.value, data.level.value);

    const level_field = getField(level, "value");
    try std.testing.expectEqual(level_field, data.level.value);
}

test "strings" {
    var data = .{ .value = "hello", .level = .{ .value = "world" } };

    const field = getField(&data, "value");
    try std.testing.expectEqualStrings(field, data.value);

    const level = getField(&data, "level");
    try std.testing.expectEqualStrings(level.value, data.level.value);

    const level_field = getField(level, "value");
    try std.testing.expectEqualStrings(level_field, data.level.value);
}

test "slices" {
    const Data = struct {
        value: []const u8,
        level: struct {
            value: []const u8,
        },
    };

    var data = Data{ .value = "hello", .level = .{ .value = "world" } };

    const field = getField(&data, "value");
    try std.testing.expectEqualStrings(field, data.value);

    const level = getField(&data, "level");
    try std.testing.expectEqualStrings(level.value, data.level.value);

    const level_field = getField(level, "value");
    try std.testing.expectEqualStrings(level_field, data.level.value);
}

test "slices items" {
    const Item = struct {
        value: []const u8,
    };
    const Data = struct {
        values: []Item,
    };

    var items = [_]Item{
        Item{ .value = "aaa" },
        Item{ .value = "bbb" },
        Item{ .value = "ccc" },
    };
    var data = Data{ .values = &items };

    const field = getField(&data, "values");
    try std.testing.expectEqual(field.len, data.values.len);

    var item0 = getElement(field, 0);
    try std.testing.expectEqual(item0.value, data.values[0].value);

    item0.value = "changed 0";
    try std.testing.expectEqual(item0.value, data.values[0].value);

    var item1 = getElement(field, 1);
    try std.testing.expectEqual(item1.value, data.values[1].value);

    item1.value = "changed 1";
    try std.testing.expectEqual(item1.value, data.values[1].value);

    var item2 = getElement(field, 2);
    try std.testing.expectEqual(item2.value, data.values[2].value);

    item2.value = "changed 2";
    try std.testing.expectEqual(item2.value, data.values[2].value);
}

test "array items" {
    const Item = struct {
        value: []const u8,
    };

    const Data = struct {
        values: [3]Item,
    };

    var data = Data{
        .values = [_]Item{
            Item{ .value = "aaa" },
            Item{ .value = "bbb" },
            Item{ .value = "ccc" },
        },
    };

    const field = getField(&data, "values");
    try std.testing.expectEqual(field.len, data.values.len);

    var item0 = getElement(field, 0);
    try std.testing.expectEqual(item0.value, data.values[0].value);

    item0.value = "changed 0";
    try std.testing.expectEqual(item0.value, data.values[0].value);

    var item1 = getElement(field, 1);
    try std.testing.expectEqual(item1.value, data.values[1].value);

    item1.value = "changed 1";
    try std.testing.expectEqual(item1.value, data.values[1].value);

    var item2 = getElement(field, 2);
    try std.testing.expectEqual(item2.value, data.values[2].value);

    item2.value = "changed 2";
    try std.testing.expectEqual(item2.value, data.values[2].value);
}

test "tuple items" {
    var data = .{
        .values = .{
            .{ .value = "aaa" },
            .{ .value = "bbb" },
            .{ .value = "ccc" },
        },
    };

    const field = getField(&data, "values");
    try std.testing.expectEqual(field.len, data.values.len);

    const item0 = getTupleElement(field, 0);
    try std.testing.expectEqual(item0.value, data.values[0].value);

    const item1 = getTupleElement(field, 1);
    try std.testing.expectEqual(item1.value, data.values[1].value);

    const item2 = getTupleElement(field, 2);
    try std.testing.expectEqual(item2.value, data.values[2].value);
}

test "optionals" {
    const Data = struct {
        value1: ?[]const u8,
        value2: ?[]const u8,
        level: ?struct {
            value1: ?[]const u8,
            value2: ?[]const u8,
        },
    };

    var data = Data{ .value1 = "hello", .value2 = null, .level = .{ .value1 = "world", .value2 = null } };

    const field1 = getField(&data, "value1");
    try std.testing.expect(field1 != null);
    try std.testing.expectEqualStrings(field1.?, data.value1.?);

    const field2 = getField(&data, "value2");
    try std.testing.expect(field2 == null);

    const level = getField(&data, "level");
    try std.testing.expect(level.*.?.value1 != null);
    try std.testing.expectEqualStrings(level.*.?.value1.?, data.level.?.value1.?);
    try std.testing.expect(level.*.?.value2 == null);

    const level_field1 = getField(level, "value1");
    try std.testing.expect(level_field1 != null);
    try std.testing.expectEqualStrings(level_field1.?, data.level.?.value1.?);

    const level_field2 = getField(level, "value2");
    try std.testing.expect(level_field2 == null);
}

test "optional pointers" {
    const SubData = struct {
        value: []const u8,
        level: ?*@This(),
    };

    const Data = struct {
        value1: ?*SubData,
        value2: ?*const SubData,
        value3: ?*SubData,
    };

    var value1 = SubData{
        .value = "hello",
        .level = null,
    };
    var value2 = SubData{
        .value = "world",
        .level = &value1,
    };
    var data = Data{ .value1 = &value1, .value2 = &value2, .value3 = null };

    var field1 = getField(&data, "value1");
    try std.testing.expect(field1 != null);
    try std.testing.expectEqualStrings(field1.?.value, data.value1.?.value);

    data.value1.?.value = "changed";
    try std.testing.expectEqualStrings(field1.?.value, data.value1.?.value);

    field1.?.value = "changed again";
    try std.testing.expectEqualStrings(field1.?.value, data.value1.?.value);

    const field1_value = getField(field1, "value");
    try std.testing.expectEqualStrings(field1_value, data.value1.?.value);

    const field1_level = getField(field1, "level");
    try std.testing.expect(field1_level == null);

    const field2 = getField(&data, "value2");
    try std.testing.expect(field2 != null);
    try std.testing.expectEqualStrings(field2.?.value, data.value2.?.value);

    const field2_value = getField(field2, "value");
    try std.testing.expectEqualStrings(field2_value, data.value2.?.value);

    const field2_level = getField(field2, "level");
    try std.testing.expectEqualStrings(field2_level.?.value, data.value2.?.level.?.value);

    const field3 = getField(&data, "value3");
    try std.testing.expect(field3 == null);
}

test "ref optionals" {
    const SubData = struct {
        value: []const u8,
    };

    const Data = struct {
        value1: ?SubData,
        value2: ?SubData,
        level: struct {
            value1: ?SubData,
            value2: ?SubData,
        },
    };

    var data = Data{ .value1 = SubData{ .value = "hello" }, .value2 = null, .level = .{ .value1 = SubData{ .value = "world" }, .value2 = null } };

    const field1 = getField(&data, "value1");
    try std.testing.expect(field1.* != null);
    try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

    const field2 = getField(&data, "value2");
    try std.testing.expect(field2.* == null);

    data.value1.?.value = "changed";
    try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

    field1.*.?.value = "changed again";
    try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

    const level = getField(&data, "level");
    try std.testing.expect(level.value1 != null);
    try std.testing.expectEqualStrings(level.value1.?.value, data.level.value1.?.value);
    try std.testing.expect(level.value2 == null);

    data.level.value1.?.value = "changed too";
    try std.testing.expectEqualStrings(level.value1.?.value, data.level.value1.?.value);

    const level_field1 = getField(level, "value1");
    try std.testing.expect(level_field1.* != null);
    try std.testing.expectEqualStrings(level_field1.*.?.value, data.level.value1.?.value);

    const level_field2 = getField(level, "value2");
    try std.testing.expect(level_field2.* == null);

    data.level.value1.?.value = "changed one more time";
    try std.testing.expectEqualStrings(level_field1.*.?.value, data.level.value1.?.value);

    level_field1.*.?.value = "changed from here";
    try std.testing.expectEqualStrings(level_field1.*.?.value, data.level.value1.?.value);
}

test "zero size" {
    const Empty = struct {};
    const SingleEnum = enum { OnlyOption };
    const Data = struct {
        value1: u0,
        value2: []const Empty,
        value3: void,
        value4: SingleEnum,
    };

    var data = Data{ .value1 = 0, .value2 = &.{ Empty{}, Empty{}, Empty{} }, .value3 = {}, .value4 = .OnlyOption };

    const field1 = getField(&data, "value1");
    try std.testing.expect(field1 == 0);
    try std.testing.expect(@sizeOf(@TypeOf(field1)) == 0);

    const field2 = getField(&data, "value2");
    try std.testing.expect(field2.len == 3);
    try std.testing.expect(@sizeOf(@TypeOf(field2)) == @sizeOf([]const Empty));

    const field3 = getField(&data, "value3");
    try std.testing.expect(field3 == {});
    try std.testing.expect(@sizeOf(@TypeOf(field3)) == 0);

    const field4 = getField(&data, "value4");
    try std.testing.expect(field4 == .OnlyOption);
    try std.testing.expect(@sizeOf(@TypeOf(field4)) == 0);
}

test "nested" {
    const Data = struct {
        value: []const u8,
        level: struct { value: []const u8, sub_level: struct {
            value: []const u8,
        } },
    };

    // Asserts that all pointers will remain valid and not ever be derrefed on the stack
    const Funcs = struct {
        fn level(data: anytype) FieldRef(@TypeOf(data), "level") {
            return getField(data, "level");
        }

        fn sub_level(data: anytype) FieldRef(FieldRef(@TypeOf(data), "level"), "sub_level") {
            const value = getField(data, "level");
            return getField(value, "sub_level");
        }
    };

    var data = Data{ .value = "hello", .level = .{ .value = "world", .sub_level = .{ .value = "from zig" } } };

    var level = Funcs.level(&data);
    try std.testing.expectEqualStrings(level.value, data.level.value);
    try std.testing.expectEqualStrings(level.sub_level.value, data.level.sub_level.value);

    data.level.value = "changed";
    try std.testing.expectEqualStrings(level.value, data.level.value);

    data.level.sub_level.value = "changed too";
    try std.testing.expectEqualStrings(level.sub_level.value, data.level.sub_level.value);

    var sub_level = Funcs.sub_level(&data);
    try std.testing.expectEqualStrings(sub_level.value, data.level.sub_level.value);

    data.level.sub_level.value = "changed one more time";
    try std.testing.expectEqualStrings(level.sub_level.value, data.level.sub_level.value);
    try std.testing.expectEqualStrings(sub_level.value, data.level.sub_level.value);

    level.sub_level.value = "changed from elsewhere";
    try std.testing.expectEqualStrings(level.sub_level.value, data.level.sub_level.value);
    try std.testing.expectEqualStrings(sub_level.value, data.level.sub_level.value);

    sub_level.value = "changed from elsewhere again";
    try std.testing.expectEqualStrings(level.sub_level.value, data.level.sub_level.value);
    try std.testing.expectEqualStrings(sub_level.value, data.level.sub_level.value);
}
