const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;

const testing = std.testing;
const assert = std.debug.assert;

const stdx = @import("../../../stdx.zig");

const mustache = @import("../../../mustache.zig");
const Element = mustache.Element;
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;

const context = @import("../../context.zig");
const PathResolutionType = context.PathResolutionType;
const Fields = context.Fields;
const Escape = context.Escape;
const LambdaContext = context.LambdaContext;

const rendering = @import("../../rendering.zig");
const map = @import("../../partials_map.zig");
const lambda = @import("lambda.zig");
const LambdaInvokerType = lambda.LambdaInvokerType;

pub fn InvokerType(
    comptime Writer: type,
    comptime PartialsMap: type,
    comptime UserData: type,
    comptime options: RenderOptions,
) type {
    const RenderEngine = rendering.RenderEngineType(
        .native,
        Writer,
        PartialsMap,
        UserData,
        options,
    );
    const Context = RenderEngine.Context;
    const DataRender = RenderEngine.DataRender;

    return struct {
        fn PathInvokerType(
            comptime TError: type,
            comptime TReturn: type,
            comptime action_fn: anytype,
        ) type {
            const action_type_info = @typeInfo(@TypeOf(action_fn));
            if (action_type_info != .Fn) @compileError("action_fn must be a function");

            return struct {
                const PathResolution = PathResolutionType(TReturn);

                const Depth = enum { Root, Leaf };

                pub inline fn call(
                    action_param: anytype,
                    data: anytype,
                    path: Element.Path,
                    index: ?usize,
                ) TError!PathResolution {
                    return find(.Root, action_param, data, path, index);
                }

                fn find(
                    depth: Depth,
                    action_param: anytype,
                    data: anytype,
                    path: Element.Path,
                    index: ?usize,
                ) TError!PathResolution {
                    const Data = @TypeOf(data);
                    if (Data == void) return .chain_broken;

                    const ctx = Fields.getRuntimeValue(data);

                    if (comptime lambda.isLambdaInvoker(if (action_param.len > 0 and DataRender.TGlobalLambdas == Data) UserData else Data)) {
                        return PathResolution{ .lambda = try action_fn(action_param, ctx) };
                    } else {
                        if (path.len > 0) {
                            return recursiveFind(depth, Data, action_param, ctx, path[0], path[1..], index);
                        } else if (index) |current_index| {
                            return iterateAt(Data, action_param, ctx, current_index);
                        } else {
                            return PathResolution{ .field = try action_fn(action_param, ctx) };
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
                ) TError!PathResolution {
                    const Data = @TypeOf(data);
                    switch (@typeInfo(TValue)) {
                        .Struct => {
                            return findFieldPath(
                                depth,
                                TValue,
                                action_param,
                                data,
                                current_path_part,
                                next_path_parts,
                                index,
                            );
                        },
                        .Pointer => |info| switch (info.size) {
                            .One => return try recursiveFind(
                                depth,
                                info.child,
                                action_param,
                                data,
                                current_path_part,
                                next_path_parts,
                                index,
                            ),
                            .Slice => {
                                //Slice supports the "len" field,
                                if (next_path_parts.len == 0 and std.mem.eql(u8, "len", current_path_part)) {
                                    return if (next_path_parts.len == 0)
                                        PathResolution{
                                            .field = try action_fn(action_param, Fields.lenOf(Data, data)),
                                        }
                                    else
                                        .chain_broken;
                                }
                            },
                            .Many => @compileError("[*] pointers not supported"),
                            .C => @compileError("[*c] pointers not supported"),
                        },
                        .Optional => |info| {
                            if (!Fields.isNull(Data, data)) {
                                return try recursiveFind(
                                    depth,
                                    info.child,
                                    action_param,
                                    data,
                                    current_path_part,
                                    next_path_parts,
                                    index,
                                );
                            }
                        },
                        .Array, .Vector => {
                            //Slice supports the "len" field,
                            if (next_path_parts.len == 0 and std.mem.eql(u8, "len", current_path_part)) {
                                return if (next_path_parts.len == 0)
                                    PathResolution{
                                        .field = try action_fn(action_param, Fields.lenOf(Data, data)),
                                    }
                                else
                                    .chain_broken;
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
                ) TError!PathResolution {
                    const fields = std.meta.fields(TValue);
                    inline for (fields) |field| {
                        if (std.mem.eql(u8, field.name, current_path_part)) {
                            return try find(.Leaf, action_param, Fields.getField(data, field.name), next_path_parts, index);
                        }
                    } else {
                        if (next_path_parts.len == 0) {
                            return try findLambdaPath(depth, TValue, action_param, data, current_path_part);
                        } else {
                            return if (depth == .Root) .not_found_in_context else .chain_broken;
                        }
                    }
                }

                fn findLambdaPath(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    current_path_part: []const u8,
                ) TError!PathResolution {
                    const decls = comptime std.meta.declarations(TValue);
                    inline for (decls) |decl| {
                        const has_fn = comptime meta.hasFn(TValue, decl.name);
                        if (has_fn) {
                            const bound_fn = @field(TValue, decl.name);
                            // TODO: How to pass Data type when TValue is the global lambda type here ??
                            const is_valid_lambda = comptime lambda.isValidLambdaFunction(if (action_param.len > 0 and DataRender.TGlobalLambdas == TValue) UserData else TValue, @TypeOf(bound_fn));
                            if (std.mem.eql(u8, current_path_part, decl.name)) {
                                if (is_valid_lambda) {
                                    return try getLambda(
                                        action_param,
                                        Fields.lhs(@TypeOf(data), data),
                                        bound_fn,
                                    );
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
                ) TError!PathResolution {
                    const TData = @TypeOf(data);
                    const TFn = @TypeOf(bound_fn);
                    const params_len = @typeInfo(TFn).Fn.params.len;

                    // Lambdas cannot be used for navigation through a path
                    // Examples:
                    // Path: "person.lambda.address" > Returns "chain_broken"
                    // Path: "person.address.lambda" > "Resolved"

                    const LambdaInvoker = if (params_len == 1)
                        LambdaInvokerType(void, TFn)
                    else
                        LambdaInvokerType(if (action_param.len > 0 and DataRender.TGlobalLambdas == TData) UserData else TData, TFn);

                    // TData is likely a pointer, or a primitive value (See Field.byValue)
                    // This struct will be copied by value to the lambda context
                    const invoker = LambdaInvoker{
                        .bound_fn = bound_fn,
                        .data = if (params_len == 1) {} else if (action_param.len > 0 and DataRender.TGlobalLambdas == TData)
                            action_param.@"0".stack.ctx.ctx.get(UserData)
                        else
                            data,
                    };

                    return PathResolution{ .lambda = try action_fn(action_param, invoker) };
                }

                fn iterateAt(
                    comptime TValue: type,
                    action_param: anytype,
                    data: anytype,
                    index: usize,
                ) TError!PathResolution {
                    const Data = @TypeOf(data);
                    switch (@typeInfo(TValue)) {
                        .Struct => |info| {
                            if (info.is_tuple) {
                                const derref = comptime stdx.isSingleItemPtr(Data);
                                inline for (0..info.fields.len) |i| {
                                    if (index == i) {
                                        return PathResolution{
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
                                PathResolution{ .field = try action_fn(action_param, data) }
                            else
                                .iterator_consumed;
                        },
                        .Pointer => |info| switch (info.size) {
                            .One => {
                                return try iterateAt(
                                    info.child,
                                    action_param,
                                    Fields.lhs(Data, data),
                                    index,
                                );
                            },
                            .Slice => {
                                //Slice of u8 is always string
                                if (info.child != u8) {
                                    return if (index < data.len)
                                        PathResolution{
                                            .field = try action_fn(
                                                action_param,
                                                Fields.getElement(Fields.lhs(Data, data), index),
                                            ),
                                        }
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
                                    PathResolution{
                                        .field = try action_fn(
                                            action_param,
                                            Fields.getElement(Fields.lhs(Data, data), index),
                                        ),
                                    }
                                else
                                    .iterator_consumed;
                            }
                        },
                        .Vector => {
                            return if (index < data.len)
                                PathResolution{
                                    .field = try action_fn(
                                        action_param,
                                        Fields.getElement(Fields.lhs(Data, data), index),
                                    ),
                                }
                            else
                                .iterator_consumed;
                        },
                        .Optional => |info| {
                            return if (!Fields.isNull(Data, data))
                                try iterateAt(
                                    info.child,
                                    action_param,
                                    Fields.lhs(Data, data),
                                    index,
                                )
                            else
                                .iterator_consumed;
                        },
                        else => {},
                    }

                    return if (index == 0)
                        PathResolution{
                            .field = try action_fn(action_param, data),
                        }
                    else
                        .iterator_consumed;
                }
            };
        }

        pub inline fn get(
            data: anytype,
            path: Element.Path,
            index: ?usize,
        ) PathResolutionType(Context) {
            const GetPathInvoker = PathInvokerType(error{}, Context, getAction);
            return GetPathInvoker.call(
                .{},
                data,
                path,
                index,
            ) catch unreachable;
        }

        pub inline fn interpolate(
            data_render: *DataRender,
            data: anytype,
            path: Element.Path,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            const InterpolatePathInvoker = PathInvokerType(
                Allocator.Error || Writer.Error,
                void,
                interpolateAction,
            );
            return InterpolatePathInvoker.call(
                .{ data_render, escape },
                data,
                path,
                null,
            );
        }

        pub inline fn capacityHint(
            data_render: *DataRender,
            data: anytype,
            path: Element.Path,
        ) PathResolutionType(usize) {
            const CapacityHintPathInvoker = PathInvokerType(error{}, usize, capacityHintAction);
            return CapacityHintPathInvoker.call(
                .{data_render},
                data,
                path,
                null,
            ) catch unreachable;
        }

        pub inline fn expandLambda(
            data_render: *DataRender,
            data: anytype,
            inner_text: []const u8,
            escape: Escape,
            delimiters: Delimiters,
            path: Element.Path,
        ) (Allocator.Error || Writer.Error)!PathResolutionType(void) {
            const ExpandLambdaPathInvoker = PathInvokerType(
                Allocator.Error || Writer.Error,
                void,
                expandLambdaAction,
            );
            return ExpandLambdaPathInvoker.call(
                .{ data_render, inner_text, escape, delimiters },
                data,
                path,
                null,
            );
        }

        fn getAction(params: anytype, value: anytype) error{}!Context {
            _ = params;
            return RenderEngine.getContextType(value);
        }

        fn interpolateAction(
            params: anytype,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            if (comptime !stdx.isTuple(@TypeOf(params)) and params.len != 2) {
                @compileError("Incorrect params " ++ @typeName(@TypeOf(params)));
            }

            var data_render: *DataRender = params.@"0";
            const escape: Escape = params.@"1";
            _ = try data_render.write(value, escape);
        }

        fn capacityHintAction(
            params: anytype,
            value: anytype,
        ) error{}!usize {
            const data_render: *DataRender = params.@"0";
            return data_render.valueCapacityHint(value);
        }

        fn expandLambdaAction(
            params: anytype,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            if (comptime !stdx.isTuple(@TypeOf(params)) and params.len != 4) {
                @compileError("Incorrect params " ++ @typeName(@TypeOf(params)));
            }

            if (comptime !lambda.isLambdaInvoker(@TypeOf(value))) return;

            const Error = Allocator.Error || Writer.Error;

            const data_render: *DataRender = params.@"0";
            const inner_text: []const u8 = params.@"1";
            const escape: Escape = params.@"2";
            const delimiters: Delimiters = params.@"3";

            const Impl = lambda.LambdaContextImplType(Writer, PartialsMap, UserData, options);
            var impl = Impl{
                .data_render = data_render,
                .escape = escape,
                .delimiters = delimiters,
            };

            const lambda_context = impl.ContextType(inner_text);

            // Errors are intentionally ignored on lambda calls, interpolating empty strings
            value.invoke(lambda_context) catch |e| {
                if (isOnErrorSet(Error, e)) {
                    const err: Error = @errorCast(e);
                    return err;
                }
            };
        }
    };
}

// Check if an error is part of a error set
// https://github.com/ziglang/zig/issues/2473
fn isOnErrorSet(comptime Error: type, value: anyerror) bool {
    switch (@typeInfo(Error)) {
        .ErrorSet => |info| if (info) |errors| {
            if (@typeInfo(@TypeOf(value)) == .ErrorSet) {
                inline for (errors) |item| {
                    const int_value = @intFromError(@field(Error, item.name));
                    if (int_value == @intFromError(value)) return true;
                }
            }
        },
        else => {},
    }

    return false;
}

const comptime_tests_enabled = @import("build_comptime_tests").comptime_tests_enabled;
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
    _ = invoker_tests;
}

const invoker_tests = struct {
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

    const parsing = @import("../../../parsing/parser.zig");
    const dummy_options = RenderOptions{ .template = .{} };
    const DummyParser = parsing.ParserType(.{
        .source = .{ .string = .{ .copy_strings = false } },
        .output = .render,
        .load_mode = .runtime_loaded,
    });
    const DummyWriter = @TypeOf(std.io.null_writer);
    const DummyPartialsMap = map.PartialsMapType(
        void,
        dummy_options,
    );
    const DummyRenderEngine = rendering.RenderEngineType(
        .native,
        DummyWriter,
        DummyPartialsMap,
        dummy_options,
    );
    const DummyInvoker = InvokerType(
        DummyWriter,
        DummyPartialsMap,
        dummy_options,
    );
    const DummyPathInvoker = DummyInvoker.PathInvokerType(
        error{},
        bool,
        dummyAction,
    );

    fn dummyAction(comptime TExpected: type, value: anytype) error{}!bool {
        const TValue = @TypeOf(value);
        const expected = comptime (TExpected == TValue) or
            (stdx.isSingleItemPtr(TValue) and meta.Child(TValue) == TExpected);
        if (!expected) {
            std.log.err(
                \\ Invalid iterator type
                \\ Expected \"{s}\"
                \\ Found \"{s}\"
            , .{ @typeName(TExpected), @typeName(TValue) });
        }
        return expected;
    }

    fn dummySeek(comptime TExpected: type, data: anytype, identifier: []const u8, index: ?usize) !DummyPathInvoker.PathResolution {
        var parser = try DummyParser.init(testing.allocator, "", .{});
        defer parser.deinit();

        const path = try parser.parsePath(identifier);
        defer Element.destroyPath(testing.allocator, false, path);

        return try DummyPathInvoker.call(TExpected, &data, path, index);
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
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectFound(Data, data, "");
    }

    test "Comptime seek - dot" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectFound(Data, data, ".");
    }

    test "Comptime seek - not found" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectNotFound(data, "wrong");
    }

    test "Comptime seek - found" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectFound(@TypeOf(data.a1), data, "a1");

        try expectFound(@TypeOf(data.a2), data, "a2");
    }

    test "Comptime seek - self null" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data: ?Data = null;
        try expectFound(?Data, data, "");
    }

    test "Comptime seek - self dot" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data: ?Data = null;
        try expectFound(?Data, data, ".");
    }

    test "Comptime seek - found nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectFound(@TypeOf(data.a1.b1), data, "a1.b1");
        try expectFound(@TypeOf(data.a1.b2), data, "a1.b2");
        try expectFound(@TypeOf(data.a1.b1.c1), data, "a1.b1.c1");
        try expectFound(@TypeOf(data.a1.b1.c1.d1), data, "a1.b1.c1.d1");
        try expectFound(@TypeOf(data.a1.b1.c1.d2), data, "a1.b1.c1.d2");
    }

    test "Comptime seek - not found nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectNotFound(data, "a1.wong");
        try expectNotFound(data, "a1.b1.wong");
        try expectNotFound(data, "a1.b2.wrong");
        try expectNotFound(data, "a1.b1.c1.wrong");
        try expectNotFound(data, "a1.b1.c1.d1.wrong");
        try expectNotFound(data, "a1.b1.c1.d2.wrong");
    }

    test "Comptime seek - null nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectFound(@TypeOf(data.a_null), data, "a_null");
        try expectFound(@TypeOf(data.a1.b_null), data, "a1.b_null");
        try expectFound(@TypeOf(data.a1.b1.c_null), data, "a1.b1.c_null");
        try expectFound(@TypeOf(data.a1.b1.c1.d_null), data, "a1.b1.c1.d_null");
    }

    test "Comptime iter - self" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(Data, data, "", 0);
    }

    test "Comptime iter consumed - self" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterNotFound(data, "", 1);
    }

    test "Comptime iter - dot" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(Data, data, ".", 0);
    }

    test "Comptime iter consumed - dot" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterNotFound(data, ".", 1);
    }

    test "Comptime seek - not found 2" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterNotFound(data, "wrong", 0);
        try expectIterNotFound(data, "wrong", 1);
    }

    test "Comptime iter - found" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(@TypeOf(data.a1), data, "a1", 0);
        try expectIterFound(@TypeOf(data.a2), data, "a2", 0);
    }

    test "Comptime iter consumed - found" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterNotFound(data, "a1", 1);

        try expectIterNotFound(data, "a2", 1);
    }

    test "Comptime iter - found nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(@TypeOf(data.a1.b1), data, "a1.b1", 0);
        try expectIterFound(@TypeOf(data.a1.b2), data, "a1.b2", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1), data, "a1.b1.c1", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d1), data, "a1.b1.c1.d1", 0);
        try expectIterFound(@TypeOf(data.a1.b1.c1.d2), data, "a1.b1.c1.d2", 0);
    }

    test "Comptime iter consumed - found nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterNotFound(data, "a1.b1", 1);
        try expectIterNotFound(data, "a1.b2", 1);
        try expectIterNotFound(data, "a1.b1.c1", 1);
        try expectIterNotFound(data, "a1.b1.c1.d1", 1);
        try expectIterNotFound(data, "a1.b1.c1.d2", 1);
    }

    test "Comptime iter - not found nested" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
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
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(@TypeOf(data.a_slice[0]), data, "a_slice", 0);

        try expectIterFound(@TypeOf(data.a_slice[1]), data, "a_slice", 1);

        try expectIterFound(@TypeOf(data.a_slice[2]), data, "a_slice", 2);

        try expectIterNotFound(data, "a_slice", 3);
    }

    test "Comptime iter - array" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(@TypeOf(data.a_array[0]), data, "a_array", 0);
        try expectIterFound(@TypeOf(data.a_array[1]), data, "a_array", 1);
        try expectIterFound(@TypeOf(data.a_array[2]), data, "a_array", 2);
        try expectIterNotFound(data, "a_array", 3);
    }

    test "Comptime iter - tuple" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
        try expectIterFound(@TypeOf(data.a_tuple[0]), data, "a_tuple", 0);
        try expectIterFound(@TypeOf(data.a_tuple[1]), data, "a_tuple", 1);
        try expectIterFound(@TypeOf(data.a_tuple[2]), data, "a_tuple", 2);
        try expectIterNotFound(data, "a_tuple", 3);
    }

    test "Comptime iter - nested slice" {
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
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
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
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
        if (!comptime_tests_enabled) return error.SkipZigTest;
        const data = Data{};
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
