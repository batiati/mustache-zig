const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;

const context = @import("context.zig");
const PathResolution = context.PathResolution;
const Escape = context.Escape;

const rendering = @import("rendering.zig");
const map = @import("partials_map.zig");

const lambda = @import("lambda.zig");
const LambdaContext = lambda.LambdaContext;
const LambdaInvoker = lambda.LambdaInvoker;

const testing = std.testing;
const assert = std.debug.assert;

// TODO: There is no need to JSON contexts be dynamic invoked
// Add a new Context aware way to resolve the path
pub const FlattenedType = [@sizeOf(std.json.Value) / @sizeOf(usize)]usize;

pub fn Invoker(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(Writer, PartialsMap, options);
    const Context = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;

    return struct {
        fn PathInvoker(comptime TError: type, TReturn: type, comptime action_fn: anytype) type {
            const action_type_info = @typeInfo(@TypeOf(action_fn));
            if (action_type_info != .Fn) @compileError("action_fn must be a function");

            return struct {
                const Result = PathResolution(TReturn);

                const Depth = enum { Root, Leaf };

                pub fn call(
                    action_param: anytype,
                    data: anytype,
                    path: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    return try find(.Root, action_param, data, path, index);
                }

                fn find(
                    depth: Depth,
                    action_param: anytype,
                    data: anytype,
                    path: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    const Data = @TypeOf(data);
                    if (Data == void) return .chain_broken;

                    const ctx = Fields.getRuntimeValue(data);

                    if (comptime lambda.isLambdaInvoker(Data)) {
                        return Result{ .lambda = try action_fn(action_param, ctx) };
                    } else {
                        if (path.len > 0) {
                            return try recursiveFind(depth, Data, action_param, ctx, path[0], path[1..], index);
                        } else if (index) |current_index| {
                            return try iterateAt(Data, action_param, ctx, current_index);
                        } else {
                            return Result{ .field = try action_fn(action_param, ctx) };
                        }
                    }
                }

                fn recursiveFind(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    current_path_part: []const u8,
                    next_path_parts: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    const typeInfo = @typeInfo(TValue);

                    switch (typeInfo) {
                        .Struct => {
                            return try findFieldPath(depth, TValue, action_param, data, current_path_part, next_path_parts, index);
                        },
                        .Pointer => |info| switch (info.size) {
                            .One => return try recursiveFind(depth, info.child, action_param, data, current_path_part, next_path_parts, index),
                            .Slice => {

                                //Slice supports the "len" field,
                                if (next_path_parts.len == 0 and std.mem.eql(u8, "len", current_path_part)) {
                                    return try find(.Leaf, action_param, Fields.lenOf(data), next_path_parts, index);
                                }
                            },

                            .Many => @compileError("[*] pointers not supported"),
                            .C => @compileError("[*c] pointers not supported"),
                        },
                        .Optional => |info| {
                            if (!Fields.isNull(data)) {
                                return try recursiveFind(depth, info.child, action_param, data, current_path_part, next_path_parts, index);
                            }
                        },
                        .Array, .Vector => {

                            //Slice supports the "len" field,
                            if (next_path_parts.len == 0 and std.mem.eql(u8, "len", current_path_part)) {
                                return try find(.Leaf, action_param, Fields.lenOf(data), next_path_parts, index);
                            }
                        },
                        else => {},
                    }

                    return if (depth == .Root) .not_found_in_context else .chain_broken;
                }

                fn findFieldPath(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    current_path_part: []const u8,
                    next_path_parts: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    const fields = std.meta.fields(TValue);
                    inline for (fields) |field| {
                        if (std.mem.eql(u8, field.name, current_path_part)) {
                            return try find(.Leaf, action_param, Fields.getField(data, field.name), next_path_parts, index);
                        }
                    } else {
                        return try findLambdaPath(depth, TValue, action_param, data, current_path_part, next_path_parts, index);
                    }
                }

                fn findLambdaPath(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    current_path_part: []const u8,
                    next_path_parts: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    const decls = comptime std.meta.declarations(TValue);
                    inline for (decls) |decl| {
                        const has_fn = comptime decl.is_pub and trait.hasFn(decl.name)(TValue);
                        if (has_fn) {
                            const bound_fn = @field(TValue, decl.name);
                            const is_valid_lambda = comptime lambda.isValidLambdaFunction(TValue, @TypeOf(bound_fn));
                            if (std.mem.eql(u8, current_path_part, decl.name)) {
                                if (is_valid_lambda) {
                                    return try getLambda(action_param, Fields.lhs(data), bound_fn, next_path_parts, index);
                                } else {
                                    return .chain_broken;
                                }
                            }
                        }
                    } else {
                        return if (depth == .Root) .not_found_in_context else .chain_broken;
                    }
                }

                fn getLambda(
                    action_param: anytype,
                    data: anytype,
                    bound_fn: anytype,
                    next_path_parts: Element.Path,
                    index: ?usize,
                ) TError!Result {
                    const TData = @TypeOf(data);
                    const TFn = @TypeOf(bound_fn);
                    const args_len = @typeInfo(TFn).Fn.args.len;

                    // Lambdas cannot be used for navigation through a path
                    // Examples:
                    // Path: "person.lambda.address" > Returns "chain_broken"
                    // Path: "person.address.lambda" > "Resolved"
                    if (next_path_parts.len == 0) {
                        const Impl = if (args_len == 1) LambdaInvoker(void, TFn) else LambdaInvoker(TData, TFn);
                        var impl = Impl{
                            .bound_fn = bound_fn,
                            .data = if (args_len == 1) {} else data,
                        };

                        return try find(.Leaf, action_param, &impl, next_path_parts, index);
                    } else {
                        return .chain_broken;
                    }
                }

                fn iterateAt(
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    index: usize,
                ) TError!Result {
                    switch (@typeInfo(TValue)) {
                        .Struct => |info| {
                            if (info.is_tuple) {
                                const derref = comptime trait.isSingleItemPtr(@TypeOf(data));
                                inline for (info.fields) |_, i| {
                                    if (index == i) {
                                        return Result{
                                            .field = try action_fn(
                                                action_param,
                                                Fields.getTupleElement(if (derref) data.* else data, i),
                                            ),
                                        };
                                    }
                                } else {
                                    return .iterator_consumed;
                                }
                            }
                        },

                        // Booleans are evaluated on the iterator
                        .Bool => {
                            return if (data == true and index == 0)
                                Result{ .field = try action_fn(action_param, data) }
                            else
                                .iterator_consumed;
                        },

                        .Pointer => |info| switch (info.size) {
                            .One => {
                                return try iterateAt(info.child, action_param, Fields.lhs(data), index);
                            },
                            .Slice => {

                                //Slice of u8 is always string
                                if (info.child != u8) {
                                    return if (index < data.len)
                                        Result{ .field = try action_fn(action_param, Fields.getElement(Fields.lhs(data), index)) }
                                    else
                                        .iterator_consumed;
                                }
                            },
                            else => {},
                        },

                        .Array => |info| {

                            //Array of u8 is always string
                            if (info.child != u8) {
                                return if (index < data.len)
                                    Result{ .field = try action_fn(action_param, Fields.getElement(Fields.lhs(data), index)) }
                                else
                                    .iterator_consumed;
                            }
                        },

                        .Vector => {
                            return if (index < data.len)
                                Result{ .field = try action_fn(action_param, Fields.getElement(Fields.lhs(data), index)) }
                            else
                                .iterator_consumed;
                        },

                        .Optional => |info| {
                            return if (!Fields.isNull(data))
                                try iterateAt(info.child, action_param, Fields.lhs(data), index)
                            else
                                .iterator_consumed;
                        },
                        else => {},
                    }

                    return if (index == 0)
                        Result{ .field = try action_fn(action_param, data) }
                    else
                        .iterator_consumed;
                }
            };
        }

        pub fn get(
            data: anytype,
            path: Element.Path,
            index: ?usize,
        ) PathResolution(Context) {
            const Get = PathInvoker(error{}, Context, getAction);
            return try Get.call(
                {},
                data,
                path,
                index,
            );
        }

        pub fn interpolate(
            data_render: *DataRender,
            data: anytype,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const Interpolate = PathInvoker(Allocator.Error || Writer.Error, void, interpolateAction);
            return try Interpolate.call(
                .{ data_render, escape },
                data,
                path,
                null,
            );
        }

        pub fn capacityHint(
            data_render: *DataRender,
            data: anytype,
            path: Element.Path,
        ) PathResolution(usize) {
            const CapacityHint = PathInvoker(error{}, usize, capacityHintAction);
            return try CapacityHint.call(
                data_render,
                data,
                path,
                null,
            );
        }

        pub fn expandLambda(
            data_render: *DataRender,
            data: anytype,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
            path: Element.Path,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const ExpandLambdaAction = PathInvoker(Allocator.Error || Writer.Error, void, expandLambdaAction);
            return try ExpandLambdaAction.call(
                .{ data_render, inner_text, escape, delimiters },
                data,
                path,
                null,
            );
        }

        fn getAction(param: void, value: anytype) error{}!Context {
            _ = param;
            return context.getContext(Writer, value, PartialsMap, options);
        }

        fn interpolateAction(
            params: anytype,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            if (comptime !std.meta.trait.isTuple(@TypeOf(params)) and params.len != 2) @compileError("Incorrect params " ++ @typeName(@TypeOf(params)));

            var data_render: *DataRender = params.@"0";
            const escape: Escape = params.@"1";
            _ = try data_render.write(value, escape);
        }

        fn capacityHintAction(
            params: anytype,
            value: anytype,
        ) error{}!usize {
            return params.valueCapacityHint(value);
        }

        fn expandLambdaAction(
            params: anytype,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            if (comptime !std.meta.trait.isTuple(@TypeOf(params)) and params.len != 4) @compileError("Incorrect params " ++ @typeName(@TypeOf(params)));
            if (comptime !lambda.isLambdaInvoker(@TypeOf(value))) return;

            const Error = Allocator.Error || Writer.Error;

            const data_render: *DataRender = params.@"0";
            const inner_text: []const u8 = params.@"1";
            const escape: Escape = params.@"2";
            const delimiters: Delimiters = params.@"3";

            const Impl = lambda.LambdaContextImpl(Writer, PartialsMap, options);
            var impl = Impl{
                .data_render = data_render,
                .escape = escape,
                .delimiters = delimiters,
            };

            const lambda_context = impl.context(inner_text);

            // Errors are intentionally ignored on lambda calls, interpolating empty strings
            value.invoke(lambda_context) catch |e| {
                if (isOnErrorSet(Error, e)) {
                    return @errSetCast(Error, e);
                }
            };
        }
    };
}

pub const Fields = struct {
    pub fn getField(data: anytype, comptime field_name: []const u8) field_type: {
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

        return if (is_by_value) @field(lhs(data), field_name) else &@field(lhs(data), field_name);
    }

    pub fn getRuntimeValue(ctx: anytype) context_type: {
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

    pub fn getTupleElement(ctx: anytype, comptime index: usize) element_type: {
        const T = @TypeOf(ctx);
        assert(trait.isTuple(T));

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

    pub fn getElement(ctx: anytype, index: usize) element_type: {
        const T = @TypeOf(ctx);

        const is_indexable = trait.isIndexable(T) and !trait.isTuple(T);
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
            if (trait.is(.Optional)(T)) {
                return Lhs(meta.Child(T));
            } else if (needsDerref(T)) {
                return Lhs(meta.Child(T));
            } else {
                return T;
            }
        }
    }

    pub fn lhs(value: anytype) Lhs(@TypeOf(value)) {
        const T = @TypeOf(value);

        if (comptime trait.is(.Optional)(T)) {
            return lhs(value.?);
        } else if (comptime needsDerref(T)) {
            return lhs(value.*);
        } else {
            return value;
        }
    }

    pub fn needsDerref(comptime T: type) bool {
        comptime {
            if (trait.isSingleItemPtr(T)) {
                const Child = meta.Child(T);
                return trait.isSingleItemPtr(Child) or trait.isSlice(Child) or trait.is(.Optional)(Child);
            } else {
                return false;
            }
        }
    }

    pub fn byValue(comptime TField: type) bool {
        comptime {
            if (trait.is(.EnumLiteral)(TField)) @compileError(
                \\Enum literal is not supported for interpolation
                \\Error: ir_resolve_lazy_recurse. This is a bug in the Zig compiler
                \\Type:
            ++ @typeName(TField));

            const max_size = @sizeOf(FlattenedType);

            const is_zero_size = @sizeOf(TField) == 0;

            const is_pointer = trait.isSlice(TField) or
                trait.isSingleItemPtr(TField);

            const can_embed = @sizeOf(TField) <= max_size and
                TField == std.json.Value or
                (trait.is(.Enum)(TField) or
                trait.is(.EnumLiteral)(TField) or
                TField == bool or
                trait.isIntegral(TField) or
                trait.isFloat(TField) or
                (trait.is(.Optional)(TField) and byValue(meta.Child(TField))));

            return is_zero_size or is_pointer or can_embed;
        }
    }

    pub fn isNull(data: anytype) bool {
        return switch (@typeInfo(@TypeOf(data))) {
            .Pointer => |info| switch (info.size) {
                .One => return isNull(data.*),
                .Slice => return false,
                .Many => @compileError("[*] pointers not supported"),
                .C => @compileError("[*c] pointers not supported"),
            },
            .Optional => return data == null,
            else => return false,
        };
    }

    pub fn lenOf(data: anytype) ?usize {
        return switch (@typeInfo(@TypeOf(data))) {
            .Pointer => |info| switch (info.size) {
                .One => return null,
                .Slice => return data.len,
                .Many => @compileError("[*] pointers not supported"),
                .C => @compileError("[*c] pointers not supported"),
            },
            .Array, .Vector => return data.len,
            .Optional => if (data) |value| return lenOf(value) else null,
            else => return null,
        };
    }

    fn FieldRef(comptime T: type, comptime field_name: []const u8) type {
        comptime {
            const TField = FieldType(T, field_name);

            assert(TField != comptime_int);
            assert(TField != comptime_float);
            assert(TField != @TypeOf(.Null));

            if (trait.is(.Optional)(T)) {
                return FieldRef(meta.Child(T), field_name);
            } else if (needsDerref(T)) {
                return FieldRef(meta.Child(T), field_name);
            } else {
                const instance: T = undefined;
                return @TypeOf(if (byValue(TField)) @field(instance, field_name) else &@field(instance, field_name));
            }
        }
    }

    fn FieldType(comptime T: type, comptime field_name: []const u8) type {
        if (trait.is(.Optional)(T)) {
            const Child = meta.Child(T);
            return FieldType(Child, field_name);
        } else if (trait.isSingleItemPtr(T)) {
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
        var const_ptr: *const usize = &value;
        var ptr_ptr = &ptr;
        var const_ptr_ptr: *const *usize = &ptr;

        try std.testing.expect(needsDerref(@TypeOf(value)) == false);
        try std.testing.expect(needsDerref(@TypeOf(ptr)) == false);
        try std.testing.expect(needsDerref(@TypeOf((const_ptr))) == false);

        try std.testing.expect(needsDerref(@TypeOf(ptr_ptr)) == true);
        try std.testing.expect(needsDerref(@TypeOf(const_ptr_ptr)) == true);

        var optional: ?usize = value;
        try std.testing.expect(needsDerref(@TypeOf(optional)) == false);

        var ptr_optional: *?usize = &optional;
        try std.testing.expect(needsDerref(@TypeOf(ptr_optional)) == true);

        var optional_ptr: ?*usize = ptr;
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
        var field = getField(&data, "int");
        try std.testing.expectEqual(field, data.int);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.int, data.level.int);

        data.level.int = 1001;
        try std.testing.expectEqual(level.int, data.level.int);

        level.int = 1002;
        try std.testing.expectEqual(level.int, data.level.int);

        var level_field = getField(level, "int");
        try std.testing.expectEqual(level_field, level.int);
        try std.testing.expectEqual(level_field, data.level.int);
    }

    test "Const ref values" {
        var data = .{ .int = @as(usize, 100), .level = .{ .int = @as(usize, 1000) } };

        var field = getField(&data, "int");
        try std.testing.expectEqual(field, data.int);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.int, data.level.int);

        var level_field = getField(level, "int");
        try std.testing.expectEqual(level_field, data.level.int);
    }

    test "comptime int" {
        var data = .{ .int = 100, .level = .{ .int = 1000 } };

        var field = getField(&data, "int");
        try std.testing.expectEqual(field, data.int);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.int, data.level.int);

        var level_field = getField(level, "int");
        try std.testing.expectEqual(level_field, data.level.int);
    }

    test "comptime floats" {
        var data = .{ .float = 3.14, .level = .{ .float = std.math.f128_min } };

        var field = getField(&data, "float");
        try std.testing.expectEqual(field, data.float);
        try std.testing.expect(@TypeOf(field) == f64);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.float, data.level.float);

        var level_field = getField(level, "float");
        try std.testing.expectEqual(level_field, data.level.float);
        try std.testing.expect(@TypeOf(level_field) == f128);
    }

    test "enum literal " {

        // Skip
        // ir_resolve_lazy_recurse. This is a bug in the Zig compiler
        if (true) return error.SkipZigTest;

        var data = .{ .value = .AreYouSure, .level = .{ .value = .Totally } };

        var field = getField(&data, "value");
        try std.testing.expectEqual(field, data.value);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.value, data.level.int);

        var level_field = getField(level, "value");
        try std.testing.expectEqual(level_field, data.level.int);
    }

    test "enum" {
        const Options = enum { AreYouSure, Totally };
        var data = .{ .value = Options.AreYouSure, .level = .{ .value = Options.Totally } };

        var field = getField(&data, "value");
        try std.testing.expectEqual(field, data.value);

        var level = getField(&data, "level");
        try std.testing.expectEqual(level.value, data.level.value);

        var level_field = getField(level, "value");
        try std.testing.expectEqual(level_field, data.level.value);
    }

    test "strings" {
        var data = .{ .value = "hello", .level = .{ .value = "world" } };

        var field = getField(&data, "value");
        try std.testing.expectEqualStrings(field, data.value);

        var level = getField(&data, "level");
        try std.testing.expectEqualStrings(level.value, data.level.value);

        var level_field = getField(level, "value");
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

        var field = getField(&data, "value");
        try std.testing.expectEqualStrings(field, data.value);

        var level = getField(&data, "level");
        try std.testing.expectEqualStrings(level.value, data.level.value);

        var level_field = getField(level, "value");
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

        var field = getField(&data, "values");
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

        var field = getField(&data, "values");
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

        var field = getField(&data, "values");
        try std.testing.expectEqual(field.len, data.values.len);

        var item0 = getTupleElement(field, 0);
        try std.testing.expectEqual(item0.value, data.values[0].value);

        var item1 = getTupleElement(field, 1);
        try std.testing.expectEqual(item1.value, data.values[1].value);

        var item2 = getTupleElement(field, 2);
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

        var field1 = getField(&data, "value1");
        try std.testing.expect(field1 != null);
        try std.testing.expectEqualStrings(field1.?, data.value1.?);

        var field2 = getField(&data, "value2");
        try std.testing.expect(field2 == null);

        var level = getField(&data, "level");
        try std.testing.expect(level.*.?.value1 != null);
        try std.testing.expectEqualStrings(level.*.?.value1.?, data.level.?.value1.?);
        try std.testing.expect(level.*.?.value2 == null);

        var level_field1 = getField(level, "value1");
        try std.testing.expect(level_field1 != null);
        try std.testing.expectEqualStrings(level_field1.?, data.level.?.value1.?);

        var level_field2 = getField(level, "value2");
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

        var field1_value = getField(field1, "value");
        try std.testing.expectEqualStrings(field1_value, data.value1.?.value);

        var field1_level = getField(field1, "level");
        try std.testing.expect(field1_level == null);

        var field2 = getField(&data, "value2");
        try std.testing.expect(field2 != null);
        try std.testing.expectEqualStrings(field2.?.value, data.value2.?.value);

        var field2_value = getField(field2, "value");
        try std.testing.expectEqualStrings(field2_value, data.value2.?.value);

        var field2_level = getField(field2, "level");
        try std.testing.expectEqualStrings(field2_level.?.value, data.value2.?.level.?.value);

        var field3 = getField(&data, "value3");
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

        var field1 = getField(&data, "value1");
        try std.testing.expect(field1.* != null);
        try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

        var field2 = getField(&data, "value2");
        try std.testing.expect(field2.* == null);

        data.value1.?.value = "changed";
        try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

        field1.*.?.value = "changed again";
        try std.testing.expectEqualStrings(field1.*.?.value, data.value1.?.value);

        var level = getField(&data, "level");
        try std.testing.expect(level.value1 != null);
        try std.testing.expectEqualStrings(level.value1.?.value, data.level.value1.?.value);
        try std.testing.expect(level.value2 == null);

        data.level.value1.?.value = "changed too";
        try std.testing.expectEqualStrings(level.value1.?.value, data.level.value1.?.value);

        var level_field1 = getField(level, "value1");
        try std.testing.expect(level_field1.* != null);
        try std.testing.expectEqualStrings(level_field1.*.?.value, data.level.value1.?.value);

        var level_field2 = getField(level, "value2");
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

        var field1 = getField(&data, "value1");
        try std.testing.expect(field1 == 0);
        try std.testing.expect(@sizeOf(@TypeOf(field1)) == 0);

        var field2 = getField(&data, "value2");
        try std.testing.expect(field2.len == 3);
        try std.testing.expect(@sizeOf(@TypeOf(field2)) == @sizeOf(usize));

        var field3 = getField(&data, "value3");
        try std.testing.expect(field3 == {});
        try std.testing.expect(@sizeOf(@TypeOf(field3)) == 0);

        var field4 = getField(&data, "value4");
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
};

// Check if an error is part of a error set
// https://github.com/ziglang/zig/issues/2473
fn isOnErrorSet(comptime Error: type, value: anytype) bool {
    switch (@typeInfo(Error)) {
        .ErrorSet => |info| if (info) |errors| {
            if (@typeInfo(@TypeOf(value)) == .ErrorSet) {
                inline for (errors) |item| {
                    const int_value = @errorToInt(@field(Error, item.name));
                    if (int_value == @errorToInt(value)) return true;
                }
            }
        },
        else => {},
    }

    return false;
}

test "isOnErrorSet" {
    const A = error{ a1, a2 };
    const B = error{ b1, b2 };
    const AB = A || B;
    const Mixed = error{ a1, b2 };
    const Empty = error{};

    try testing.expect(isOnErrorSet(A, error.a1));
    try testing.expect(isOnErrorSet(A, error.a2));
    try testing.expect(!isOnErrorSet(A, error.b1));
    try testing.expect(!isOnErrorSet(A, error.b2));

    try testing.expect(isOnErrorSet(AB, error.a1));
    try testing.expect(isOnErrorSet(AB, error.a2));
    try testing.expect(isOnErrorSet(AB, error.b1));
    try testing.expect(isOnErrorSet(AB, error.b2));

    try testing.expect(isOnErrorSet(Mixed, error.a1));
    try testing.expect(!isOnErrorSet(Mixed, error.a2));
    try testing.expect(!isOnErrorSet(Mixed, error.b1));
    try testing.expect(isOnErrorSet(Mixed, error.b2));

    try testing.expect(!isOnErrorSet(Empty, error.a1));
    try testing.expect(!isOnErrorSet(Empty, error.a2));
    try testing.expect(!isOnErrorSet(Empty, error.b1));
    try testing.expect(!isOnErrorSet(Empty, error.b2));
}

test {
    _ = Fields;
    _ = tests;
}

const tests = struct {
    const Tuple = std.meta.Tuple(&.{ u8, u32, u64 });
    const Data = struct {
        a1: struct {
            b1: struct {
                c1: struct {
                    d1: u0 = 0,
                    d2: u0 = 0,
                    d_null: ?u0 = null,
                    d_slice: []const u0 = &.{ 0, 0, 0 },
                    d_array: [3]u0 = .{ 0, 0, 0 },
                    d_tuple: Tuple = Tuple{ 0, 0, 0 },
                } = .{},
                c_null: ?u0 = null,
                c_slice: []const u0 = &.{ 0, 0, 0 },
                c_array: [3]u0 = .{ 0, 0, 0 },
                c_tuple: Tuple = Tuple{ 0, 0, 0 },
            } = .{},
            b2: u0 = 0,
            b_null: ?u0 = null,
            b_slice: []const u0 = &.{ 0, 0, 0 },
            b_array: [3]u0 = .{ 0, 0, 0 },
            b_tuple: Tuple = Tuple{ 0, 0, 0 },
        } = .{},
        a2: u0 = 0,
        a_null: ?u0 = null,
        a_slice: []const u0 = &.{ 0, 0, 0 },
        a_array: [3]u0 = .{ 0, 0, 0 },
        a_tuple: Tuple = Tuple{ 0, 0, 0 },
    };

    const dummy_options = RenderOptions{ .template = .{} };
    const DummyParser = @import("../parsing/parser.zig").Parser(.{ .source = .{ .string = .{ .copy_strings = false } }, .output = .render, .load_mode = .runtime_loaded });
    const DummyWriter = @TypeOf(std.io.null_writer);
    const DummyPartialsMap = map.PartialsMap(void, dummy_options);
    const DummyRenderEngine = rendering.RenderEngine(DummyWriter, DummyPartialsMap, dummy_options);
    const DummyInvoker = DummyRenderEngine.Invoker;
    const DummyCaller = DummyInvoker.PathInvoker(error{}, bool, dummyAction);

    fn dummyAction(comptime TExpected: type, value: anytype) error{}!bool {
        const TValue = @TypeOf(value);
        const expected = comptime (TExpected == TValue) or (trait.isSingleItemPtr(TValue) and meta.Child(TValue) == TExpected);
        if (!expected) {
            std.log.err(
                \\ Invalid iterator type
                \\ Expected \"{s}\"
                \\ Found \"{s}\"
            , .{ @typeName(TExpected), @typeName(TValue) });
        }
        return expected;
    }

    fn dummySeek(comptime TExpected: type, data: anytype, identifier: []const u8, index: ?usize) !DummyCaller.Result {
        var parser = try DummyParser.init(testing.allocator, "", .{});
        defer parser.deinit();

        var path = try parser.parsePath(identifier);
        defer Element.destroyPath(testing.allocator, false, path);

        return try DummyCaller.call(TExpected, &data, path, index);
    }

    fn expectFound(comptime TExpected: type, data: anytype, path: []const u8) !void {
        const value = try dummySeek(TExpected, data, path, null);
        try testing.expect(value == .field);
        try testing.expect(value.field == true);
    }

    fn expectNotFound(data: anytype, path: []const u8) !void {
        const value = try dummySeek(void, data, path, null);
        try testing.expect(value != .field);
    }

    fn expectIterFound(comptime TExpected: type, data: anytype, path: []const u8, index: usize) !void {
        const value = try dummySeek(TExpected, data, path, index);
        try testing.expect(value == .field);
        try testing.expect(value.field == true);
    }

    fn expectIterNotFound(data: anytype, path: []const u8, index: usize) !void {
        const value = try dummySeek(void, data, path, index);
        try testing.expect(value != .field);
    }

    test "Comptime seek - self" {
        var data = Data{};
        try expectFound(Data, data, "");
    }

    test "Comptime seek - dot" {
        var data = Data{};
        try expectFound(Data, data, ".");
    }

    test "Comptime seek - not found" {
        var data = Data{};
        try expectNotFound(data, "wrong");
    }

    test "Comptime seek - found" {
        var data = Data{};
        try expectFound(@TypeOf(data.a1), data, "a1");

        try expectFound(@TypeOf(data.a2), data, "a2");
    }

    test "Comptime seek - self null" {
        var data: ?Data = null;
        try expectFound(?Data, data, "");
    }

    test "Comptime seek - self dot" {
        var data: ?Data = null;
        try expectFound(?Data, data, ".");
    }

    test "Comptime seek - found nested" {
        var data = Data{};
        try expectFound(@TypeOf(data.a1.b1), data, "a1.b1");
        try expectFound(@TypeOf(data.a1.b2), data, "a1.b2");
        try expectFound(@TypeOf(data.a1.b1.c1), data, "a1.b1.c1");
        try expectFound(@TypeOf(data.a1.b1.c1.d1), data, "a1.b1.c1.d1");
        try expectFound(@TypeOf(data.a1.b1.c1.d2), data, "a1.b1.c1.d2");
    }

    test "Comptime seek - not found nested" {
        var data = Data{};
        try expectNotFound(data, "a1.wong");
        try expectNotFound(data, "a1.b1.wong");
        try expectNotFound(data, "a1.b2.wrong");
        try expectNotFound(data, "a1.b1.c1.wrong");
        try expectNotFound(data, "a1.b1.c1.d1.wrong");
        try expectNotFound(data, "a1.b1.c1.d2.wrong");
    }

    test "Comptime seek - null nested" {
        var data = Data{};
        try expectFound(@TypeOf(data.a_null), data, "a_null");
        try expectFound(@TypeOf(data.a1.b_null), data, "a1.b_null");
        try expectFound(@TypeOf(data.a1.b1.c_null), data, "a1.b1.c_null");
        try expectFound(@TypeOf(data.a1.b1.c1.d_null), data, "a1.b1.c1.d_null");
    }

    test "Comptime iter - self" {
        var data = Data{};
        try expectIterFound(Data, data, "", 0);
    }

    test "Comptime iter consumed - self" {
        var data = Data{};
        try expectIterNotFound(data, "", 1);
    }

    test "Comptime iter - dot" {
        var data = Data{};
        try expectIterFound(Data, data, ".", 0);
    }

    test "Comptime iter consumed - dot" {
        var data = Data{};
        try expectIterNotFound(data, ".", 1);
    }

    test "Comptime seek - not found" {
        var data = Data{};
        try expectIterNotFound(data, "wrong", 0);
        try expectIterNotFound(data, "wrong", 1);
    }

    test "Comptime iter - found" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a1), data, "a1", 0);

        try expectIterFound(@TypeOf(data.a2), data, "a2", 0);
    }

    test "Comptime iter consumed - found" {
        var data = Data{};
        try expectIterNotFound(data, "a1", 1);

        try expectIterNotFound(data, "a2", 1);
    }

    test "Comptime iter - found nested" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a1.b1), data, "a1.b1", 0);
        try expectIterFound(@TypeOf(data.a1.b2), data, "a1.b2", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1), data, "a1.b1.c1", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d1), data, "a1.b1.c1.d1", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d2), data, "a1.b1.c1.d2", 0);
    }

    test "Comptime iter consumed - found nested" {
        var data = Data{};
        try expectIterNotFound(data, "a1.b1", 1);
        try expectIterNotFound(data, "a1.b2", 1);
        try expectIterNotFound(data, "a1.b1.c1", 1);
        try expectIterNotFound(data, "a1.b1.c1.d1", 1);
        try expectIterNotFound(data, "a1.b1.c1.d2", 1);
    }

    test "Comptime iter - not found nested" {
        var data = Data{};
        try expectIterNotFound(data, "a1.wong", 0);
        try expectIterNotFound(data, "a1.b1.wong", 0);
        try expectIterNotFound(data, "a1.b2.wrong", 0);
        try expectIterNotFound(data, "a1.b1.c1.wrong", 0);
        try expectIterNotFound(data, "a1.b1.c1.d1.wrong", 0);
        try expectIterNotFound(data, "a1.b1.c1.d2.wrong", 0);

        try expectIterNotFound(data, "a1.wong", 1);
        try expectIterNotFound(data, "a1.b1.wong", 1);
        try expectIterNotFound(data, "a1.b2.wrong", 1);
        try expectIterNotFound(data, "a1.b1.c1.wrong", 1);
        try expectIterNotFound(data, "a1.b1.c1.d1.wrong", 1);
        try expectIterNotFound(data, "a1.b1.c1.d2.wrong", 1);
    }

    test "Comptime iter - slice" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_slice[0]), data, "a_slice", 0);

        try expectIterFound(@TypeOf(data.a_slice[1]), data, "a_slice", 1);

        try expectIterFound(@TypeOf(data.a_slice[2]), data, "a_slice", 2);

        try expectIterNotFound(data, "a_slice", 3);
    }

    test "Comptime iter - array" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_array[0]), data, "a_array", 0);

        try expectIterFound(@TypeOf(data.a_array[1]), data, "a_array", 1);

        try expectIterFound(@TypeOf(data.a_array[2]), data, "a_array", 2);

        try expectIterNotFound(data, "a_array", 3);
    }

    test "Comptime iter - tuple" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_tuple[0]), data, "a_tuple", 0);

        try expectIterFound(@TypeOf(data.a_tuple[1]), data, "a_tuple", 1);

        try expectIterFound(@TypeOf(data.a_tuple[2]), data, "a_tuple", 2);

        try expectIterNotFound(data, "a_tuple", 3);
    }

    test "Comptime iter - nested slice" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_slice[0]), data, "a_slice", 0);
        try expectIterFound(@TypeOf(data.a1.b_slice[0]), data, "a1.b_slice", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c_slice[0]), data, "a1.b1.c_slice", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_slice[0]), data, "a1.b1.c1.d_slice", 0);

        try expectIterFound(@TypeOf(data.a_slice[1]), data, "a_slice", 1);
        try expectIterFound(@TypeOf(data.a1.b_slice[1]), data, "a1.b_slice", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c_slice[1]), data, "a1.b1.c_slice", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_slice[1]), data, "a1.b1.c1.d_slice", 1);

        try expectIterFound(@TypeOf(data.a_slice[2]), data, "a_slice", 2);
        try expectIterFound(@TypeOf(data.a1.b_slice[2]), data, "a1.b_slice", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c_slice[2]), data, "a1.b1.c_slice", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_slice[2]), data, "a1.b1.c1.d_slice", 2);

        try expectIterNotFound(data, "a_slice", 3);
        try expectIterNotFound(data, "a1.b_slice", 3);
        try expectIterNotFound(data, "a1.b1.c_slice", 3);
        try expectIterNotFound(data, "a1.b1.c1.d_slice", 3);
    }

    test "Comptime iter - nested array" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_tuple[0]), data, "a_tuple", 0);
        try expectIterFound(@TypeOf(data.a1.b_tuple[0]), data, "a1.b_tuple", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c_tuple[0]), data, "a1.b1.c_tuple", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_tuple[0]), data, "a1.b1.c1.d_tuple", 0);

        try expectIterFound(@TypeOf(data.a_tuple[1]), data, "a_tuple", 1);
        try expectIterFound(@TypeOf(data.a1.b_tuple[1]), data, "a1.b_tuple", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c_tuple[1]), data, "a1.b1.c_tuple", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_tuple[1]), data, "a1.b1.c1.d_tuple", 1);

        try expectIterFound(@TypeOf(data.a_tuple[2]), data, "a_tuple", 2);
        try expectIterFound(@TypeOf(data.a1.b_tuple[2]), data, "a1.b_tuple", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c_tuple[2]), data, "a1.b1.c_tuple", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_tuple[2]), data, "a1.b1.c1.d_tuple", 2);

        try expectIterNotFound(data, "a_tuple", 3);
        try expectIterNotFound(data, "a1.b_tuple", 3);
        try expectIterNotFound(data, "a1.b1.c_tuple", 3);
        try expectIterNotFound(data, "a1.b1.c1.d_tuple", 3);
    }

    test "Comptime iter - nested tuple" {
        var data = Data{};
        try expectIterFound(@TypeOf(data.a_array[0]), data, "a_array", 0);
        try expectIterFound(@TypeOf(data.a1.b_array[0]), data, "a1.b_array", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c_array[0]), data, "a1.b1.c_array", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_array[0]), data, "a1.b1.c1.d_array", 0);

        try expectIterFound(@TypeOf(data.a_array[1]), data, "a_array", 1);
        try expectIterFound(@TypeOf(data.a1.b_array[1]), data, "a1.b_array", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c_array[1]), data, "a1.b1.c_array", 1);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_array[1]), data, "a1.b1.c1.d_array", 1);

        try expectIterFound(@TypeOf(data.a_array[2]), data, "a_array", 2);
        try expectIterFound(@TypeOf(data.a1.b_array[2]), data, "a1.b_array", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c_array[2]), data, "a1.b1.c_array", 2);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d_array[2]), data, "a1.b1.c1.d_array", 2);

        try expectIterNotFound(data, "a_array", 3);
        try expectIterNotFound(data, "a1.b_array", 3);
        try expectIterNotFound(data, "a1.b1.c_array", 3);
        try expectIterNotFound(data, "a1.b1.c1.d_array", 3);
    }
};
