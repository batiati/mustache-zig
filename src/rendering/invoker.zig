const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const mustache = @import("../mustache.zig");
const Delimiters = mustache.Delimiters;

const context = @import("context.zig");
const PathResolution = context.PathResolution;
const Context = context.Context;
const Escape = context.Escape;

const lambda = @import("lambda.zig");
const LambdaContext = lambda.LambdaContext;
const LambdaInvoker = lambda.LambdaInvoker;

const testing = std.testing;
const assert = std.debug.assert;

const FieldHelper = @import("FieldHelper.zig");

const escapedWrite = @import("escape.zig").escapedWrite;

pub fn Invoker(comptime Writer: type) type {
    return struct {
        pub const ContextInterface = context.Context(Writer);
        pub const ContextStack = ContextInterface.ContextStack;
        pub const OutWriter = ContextInterface.OutWriter;

        pub inline fn get(
            allocator: Allocator,
            data: anytype,
            path_iterator: *std.mem.TokenIterator(u8),
            index: ?usize,
        ) Allocator.Error!PathResolution(Context(Writer)) {
            const Get = PathInvoker(Allocator.Error, Context(Writer), getAction);
            return try Get.call(
                allocator,
                {},
                data,
                path_iterator,
                index,
            );
        }

        pub inline fn interpolate(
            out_writer: OutWriter,
            data: anytype,
            path_iterator: *std.mem.TokenIterator(u8),
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const Interpolate = PathInvoker(Allocator.Error || Writer.Error, void, interpolateAction);
            return try Interpolate.call(
                escape,
                out_writer,
                data,
                path_iterator,
                null,
            );
        }

        pub inline fn check(
            data: anytype,
            path_iterator: *std.mem.TokenIterator(u8),
            index: usize,
        ) PathResolution(void) {
            const CheckAction = PathInvoker(error{}, void, checkAction);
            return try CheckAction.call(
                {},
                {},
                data,
                path_iterator,
                index,
            );
        }

        pub inline fn expandLambda(
            allocator: Allocator,
            out_writer: OutWriter,
            data: anytype,
            stack: anytype,
            tag_contents: []const u8,
            escape: Escape,
            delimiters: Delimiters,
            path_iterator: *std.mem.TokenIterator(u8),
        ) (Allocator.Error || Writer.Error)!PathResolution(void) {
            const ExpandLambdaAction = PathInvoker(Allocator.Error || Writer.Error, void, expandLambdaAction);
            return try ExpandLambdaAction.call(
                .{ allocator, stack, tag_contents, escape, delimiters },
                out_writer,
                data,
                path_iterator,
                null,
            );
        }

        fn PathInvoker(comptime TError: type, TReturn: type, comptime action_fn: anytype) type {
            const action_type_info = @typeInfo(@TypeOf(action_fn));
            if (action_type_info != .Fn) @compileError("action_fn must be a function");

            return struct {
                const Result = PathResolution(TReturn);

                const Depth = enum { Root, Leaf };

                pub inline fn call(
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    return try find(.Root, action_param, out_writer, data, path_iterator, index);
                }

                fn find(
                    depth: Depth,
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    const Data = @TypeOf(data);
                    if (Data == void) return .ChainBroken;

                    const ctx = FieldHelper.getRuntimeValue(data);

                    if (comptime lambda.isLambdaInvoker(Data)) {
                        if (index) |current_index| {
                            if (current_index > 0) return .IteratorConsumed;
                        }

                        return Result{ .Lambda = try action_fn(action_param, out_writer, ctx) };
                    } else {
                        if (path_iterator.next()) |current_path| {
                            return try recursiveFind(depth, Data, action_param, out_writer, ctx, current_path, path_iterator, index);
                        } else if (index) |current_index| {
                            return try iterateAt(Data, action_param, out_writer, ctx, current_index);
                        } else {
                            return Result{ .Field = try action_fn(action_param, out_writer, ctx) };
                        }
                    }
                }

                fn recursiveFind(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    path: []const u8,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    const typeInfo = @typeInfo(TValue);

                    switch (typeInfo) {
                        .Struct => {
                            return try findFieldPath(depth, TValue, action_param, out_writer, data, path, path_iterator, index);
                        },
                        .Pointer => |info| switch (info.size) {
                            .One => return try recursiveFind(depth, info.child, action_param, out_writer, data, path, path_iterator, index),
                            .Slice => {

                                //Slice supports the "len" field,
                                if (std.mem.eql(u8, "len", path)) {
                                    return try find(.Leaf, action_param, out_writer, lenOf(data), path_iterator, index);
                                }
                            },

                            .Many => @compileError("[*] pointers not supported"),
                            .C => @compileError("[*c] pointers not supported"),
                        },
                        .Optional => |info| {
                            if (!isNull(data)) {
                                return try recursiveFind(depth, info.child, action_param, out_writer, data, path, path_iterator, index);
                            }
                        },
                        .Array, .Vector => {

                            //Slice supports the "len" field,
                            if (std.mem.eql(u8, "len", path)) {
                                return try find(.Leaf, action_param, out_writer, lenOf(data), path_iterator, index);
                            }
                        },
                        else => {},
                    }

                    return if (depth == .Root) .NotFoundInContext else .ChainBroken;
                }

                fn isNull(data: anytype) bool {
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

                fn lenOf(data: anytype) ?usize {
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

                fn findFieldPath(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    path: []const u8,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    const fields = std.meta.fields(TValue);
                    inline for (fields) |field| {
                        if (std.mem.eql(u8, field.name, path)) {
                            return try find(.Leaf, action_param, out_writer, FieldHelper.getField(data, field.name), path_iterator, index);
                        }
                    } else {
                        return try findLambdaPath(depth, TValue, action_param, out_writer, data, path, path_iterator, index);
                    }
                }

                fn findLambdaPath(
                    depth: Depth,
                    comptime TValue: type,
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    path: []const u8,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    const decls = comptime std.meta.declarations(TValue);
                    inline for (decls) |decl| {
                        const has_fn = comptime decl.is_pub and trait.hasFn(decl.name)(TValue);
                        if (has_fn) {
                            const bound_fn = @field(TValue, decl.name);
                            const is_valid_lambda = comptime lambda.isValidLambdaFunction(TValue, @TypeOf(bound_fn));
                            if (std.mem.eql(u8, path, decl.name)) {
                                if (is_valid_lambda) {
                                    const ctx = FieldHelper.getRuntimeValue(data);
                                    return try getLambda(action_param, out_writer, FieldHelper.lhs(ctx), bound_fn, path_iterator, index);
                                } else {
                                    return .ChainBroken;
                                }
                            }
                        }
                    } else {
                        return if (depth == .Root) .NotFoundInContext else .ChainBroken;
                    }
                }

                fn getLambda(
                    action_param: anytype,
                    out_writer: anytype,
                    data: anytype,
                    bound_fn: anytype,
                    path_iterator: *std.mem.TokenIterator(u8),
                    index: ?usize,
                ) TError!Result {
                    const TData = @TypeOf(data);
                    const TFn = @TypeOf(bound_fn);
                    const args_len = @typeInfo(TFn).Fn.args.len;

                    // Lambdas cannot be used for navigation through a path
                    // Examples:
                    // Path: "person.lambda.address" > Returns "ChainBroken"
                    // Path: "person.address.lambda" > "Resolved"
                    if (path_iterator.next() == null) {
                        const Impl = if (args_len == 1) LambdaInvoker(void, TFn) else LambdaInvoker(TData, TFn);
                        var impl = Impl{
                            .bound_fn = bound_fn,
                            .data = if (args_len == 1) {} else data,
                        };

                        return try find(.Leaf, action_param, out_writer, &impl, path_iterator, index);
                    } else {
                        return .ChainBroken;
                    }
                }

                fn iterateAt(
                    comptime TValue: type,
                    action_param: anytype,
                    out_writer: anytype,
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
                                            .Field = try action_fn(
                                                action_param,
                                                out_writer,
                                                FieldHelper.getTupleElement(if (derref) data.* else data, i),
                                            ),
                                        };
                                    }
                                } else {
                                    return .IteratorConsumed;
                                }
                            }
                        },

                        // Booleans are evaluated on the iterator
                        .Bool => {
                            return if (data == true and index == 0)
                                Result{ .Field = try action_fn(action_param, out_writer, data) }
                            else
                                .IteratorConsumed;
                        },

                        .Pointer => |info| switch (info.size) {
                            .One => {
                                return try iterateAt(info.child, action_param, out_writer, FieldHelper.lhs(data), index);
                            },
                            .Slice => {

                                //Slice of u8 is always string
                                if (info.child != u8) {
                                    return if (index < data.len)
                                        Result{ .Field = try action_fn(action_param, out_writer, FieldHelper.getElement(FieldHelper.lhs(data), index)) }
                                    else
                                        .IteratorConsumed;
                                }
                            },
                            else => {},
                        },

                        .Array => |info| {

                            //Array of u8 is always string
                            if (info.child != u8) {
                                return if (index < data.len)
                                    Result{ .Field = try action_fn(action_param, out_writer, FieldHelper.getElement(FieldHelper.lhs(data), index)) }
                                else
                                    .IteratorConsumed;
                            }
                        },

                        .Vector => {
                            return if (index < data.len)
                                Result{ .Field = try action_fn(action_param, out_writer, FieldHelper.getElement(FieldHelper.lhs(data), index)) }
                            else
                                .IteratorConsumed;
                        },

                        .Optional => |info| {
                            return if (!isNull(data))
                                try iterateAt(info.child, action_param, out_writer, FieldHelper.lhs(data), index)
                            else
                                .IteratorConsumed;
                        },
                        else => {},
                    }

                    return if (index == 0)
                        Result{ .Field = try action_fn(action_param, out_writer, data) }
                    else
                        .IteratorConsumed;
                }
            };
        }

        inline fn getAction(allocator: Allocator, out_writer: void, value: anytype) Allocator.Error!ContextInterface {
            _ = out_writer;
            return try context.getContext(Writer, allocator, value);
        }

        inline fn checkAction(
            param: void,
            out_writer: void,
            value: anytype,
        ) error{}!void {
            _ = param;
            _ = out_writer;
            _ = value;
        }

        inline fn interpolateAction(
            escape: Escape,
            out_writer: OutWriter,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            switch (out_writer) {
                .Writer => |writer| try write(writer, value, escape),
                .Buffer => |list| try write(list.writer(), value, escape),
            }
        }

        inline fn expandLambdaAction(
            params: anytype,
            out_writer: OutWriter,
            value: anytype,
        ) (Allocator.Error || Writer.Error)!void {
            comptime {
                if (!std.meta.trait.isTuple(@TypeOf(params)) and params.len != 5) @compileError("Incorrect params " ++ @typeName(@TypeOf(params)));
                if (!lambda.isLambdaInvoker(@TypeOf(value))) return;
            }

            const Error = Allocator.Error || Writer.Error;
            const allocator = params.@"0";
            const stack = params.@"1";
            const inner_text = params.@"2";
            const escape = params.@"3";
            const delimiters = params.@"4";

            const Impl = lambda.LambdaContextImpl(Writer);
            var impl = Impl{
                .out_writer = out_writer,
                .stack = stack,
                .escape = escape,
                .delimiters = delimiters,
            };

            const lambda_context = impl.context(allocator, inner_text);

            // Errors are intentionally ignored on lambda calls, interpolating empty strings
            value.invoke(lambda_context) catch |e| {
                if (isOnErrorSet(Error, e)) {
                    return @errSetCast(Error, e);
                }
            };
        }

        fn write(
            writer: anytype,
            value: anytype,
            escape: Escape,
        ) (Allocator.Error || Writer.Error)!void {
            const TValue = @TypeOf(value);

            switch (@typeInfo(TValue)) {
                .Void, .Null => {},

                // what should we print for a struct?
                // maybe call fmt or stringify

                .Struct, .Opaque => {},

                .Bool => _ = try escapedWrite(writer, if (value) "true" else "false", escape),
                .Int, .ComptimeInt => try std.fmt.formatInt(value, 10, .lower, .{}, writer),
                .Float, .ComptimeFloat => try std.fmt.formatFloatDecimal(value, .{}, writer),
                .Enum => _ = try escapedWrite(writer, @tagName(value), escape),

                .Pointer => |info| switch (info.size) {
                    .One => try write(writer, value.*, escape),
                    .Slice => {
                        if (info.child == u8) {
                            _ = try escapedWrite(writer, value, escape);
                        }
                    },
                    .Many => @compileError("[*] pointers not supported"),
                    .C => @compileError("[*c] pointers not supported"),
                },
                .Array => |info| {
                    if (info.child == u8) {
                        _ = try escapedWrite(writer, &value, escape);
                    }
                },
                .Optional => {
                    if (value) |not_null| {
                        try write(writer, not_null, escape);
                    }
                },
                else => {},
            }
        }

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
            _ = tests;
            _ = @import("escape.zig");
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

            const FooCaller = PathInvoker(error{}, bool, fooAction);

            fn fooAction(comptime TExpected: type, out_writer: anytype, value: anytype) error{}!bool {
                _ = out_writer;
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

            fn fooSeek(comptime TExpected: type, data: anytype, path: []const u8, index: ?usize) !FooCaller.Result {
                var path_iterator = std.mem.tokenize(u8, path, ".");
                return try FooCaller.call(TExpected, std.io.null_writer, &data, &path_iterator, index);
            }

            fn expectFound(comptime TExpected: type, data: anytype, path: []const u8) !void {
                const value = try fooSeek(TExpected, data, path, null);
                try testing.expect(value == .Field);
                try testing.expect(value.Field == true);
            }

            fn expectNotFound(data: anytype, path: []const u8) !void {
                const value = try fooSeek(void, data, path, null);
                try testing.expect(value != .Field);
            }

            fn expectIterFound(comptime TExpected: type, data: anytype, path: []const u8, index: usize) !void {
                const value = try fooSeek(TExpected, data, path, index);
                try testing.expect(value == .Field);
                try testing.expect(value.Field == true);
            }

            fn expectIterNotFound(data: anytype, path: []const u8, index: usize) !void {
                const value = try fooSeek(void, data, path, index);
                try testing.expect(value != .Field);
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
    };
}
