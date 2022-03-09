const std = @import("std");
const Allocator = std.mem.Allocator;
const TypeInfo = std.builtin.TypeInfo;
const trait = std.meta.trait;

const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;

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
        /// The path could be resolved against the current context
        /// The payload is the result returned by "action_fn"
        Resolved: Payload,
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

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            get: fn (ctx: *anyopaque, allocator: Allocator, path: []const u8, index: ?usize) Allocator.Error!PathResolution(Self),
            write: fn (ctx: *anyopaque, path: []const u8, escape: Escape) Writer.Error!PathResolution(void),
            check: fn (ctx: *anyopaque, path: []const u8, index: usize) PathResolution(void),
            deinit: fn (ctx: *anyopaque, allocator: Allocator) void,
        };

        pub const Iterator = struct {
            context: *const Self,
            path: []const u8,
            current: usize,
            finished: bool,

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
                        .Resolved => true,
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
                        .Resolved => |found| return found,
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
                .Resolved, .IteratorConsumed => .{
                    .Resolved = .{
                        .context = self,
                        .path = path,
                        .current = 0,
                        .finished = result == .IteratorConsumed,
                    },
                },

                .ChainBroken => .ChainBroken,
                .NotFoundInContext => .NotFoundInContext,
            };
        }

        pub inline fn write(self: Self, path: []const u8, escape: Escape) Writer.Error!PathResolution(void) {
            return try self.vtable.write(self.ptr, path, escape);
        }

        pub inline fn deinit(self: Self, allocator: Allocator) void {
            return self.vtable.deinit(self.ptr, allocator);
        }
    };
}

fn ContextImpl(comptime Writer: type, comptime Data: type) type {
    return struct {
        const ContextInterface = Context(Writer);

        const vtable = ContextInterface.VTable{
            .get = get,
            .check = check,
            .write = write,
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
            return try Comptime.get(allocator, self.writer, self.data, &path_iterator, index);
        }

        fn check(ctx: *anyopaque, path: []const u8, index: usize) PathResolution(void) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return Comptime.check(self.data, &path_iterator, index);
        }

        fn write(ctx: *anyopaque, path: []const u8, escape: Escape) Writer.Error!PathResolution(void) {
            var self = getSelf(ctx);

            var path_iterator = std.mem.tokenize(u8, path, PATH_SEPARATOR);
            return try Comptime.write(self.writer, self.data, &path_iterator, escape);
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

const Comptime = struct {
    pub inline fn get(
        allocator: Allocator,
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
        index: ?usize,
    ) Allocator.Error!PathResolution(Context(@TypeOf(out_writer))) {
        const GetContext = Caller(Allocator.Error, Context(@TypeOf(out_writer)), getContext);
        return try GetContext.call(
            allocator,
            out_writer,
            data,
            path_iterator,
            index,
        );
    }

    pub inline fn write(
        out_writer: anytype,
        data: anytype,
        path_iterator: *std.mem.TokenIterator(u8),
        escape: Escape,
    ) @TypeOf(out_writer).Error!PathResolution(void) {
        const Stringify = Caller(@TypeOf(out_writer).Error, void, stringify);
        return try Stringify.call(
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
        const null_writer = std.io.null_writer;
        const NoAction = Caller(@TypeOf(null_writer).Error, void, no_action);
        return try NoAction.call(
            {},
            null_writer,
            data,
            path_iterator,
            index,
        );
    }

    fn Caller(comptime TError: type, TReturn: type, comptime action_fn: anytype) type {
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

            inline fn find(
                depth: Depth,
                action_param: anytype,
                out_writer: anytype,
                data: anytype,
                path_iterator: *std.mem.TokenIterator(u8),
                index: ?usize,
            ) TError!Result {
                if (path_iterator.next()) |token| {
                    return try recursiveFind(depth, @TypeOf(data), action_param, out_writer, data, token, path_iterator, index);
                } else {
                    const Data = @TypeOf(data);
                    if (Data == comptime_int) {
                        const RuntimeInt = if (data > 0) std.math.IntFittingRange(0, data) else std.math.IntFittingRange(data, 0);
                        var runtime_value: RuntimeInt = data;
                        return try find(depth, action_param, out_writer, runtime_value, path_iterator, index);
                    } else if (Data == comptime_float) {
                        var runtime_value: f64 = data;
                        return try find(depth, action_param, out_writer, runtime_value, path_iterator, index);
                    } else if (Data == @TypeOf(null)) {
                        var runtime_value: ?u0 = null;
                        return try find(depth, action_param, out_writer, runtime_value, path_iterator, index);
                    } else if (Data == void) {
                        return if (depth == .Root) .NotFoundInContext else .ChainBroken;
                    } else {
                        if (index) |current_index| {
                            return try iterateAt(action_param, out_writer, data, current_index);
                        } else {
                            return Result{ .Resolved = try action_fn(action_param, out_writer, data) };
                        }
                    }
                }
            }

            inline fn recursiveFind(
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
                        return try seekField(depth, TValue, action_param, out_writer, data, path, path_iterator, index);
                    },
                    .Pointer => |info| switch (info.size) {
                        .One => return try recursiveFind(depth, info.child, action_param, out_writer, data, path, path_iterator, index),
                        .Slice => {

                            //Slice supports the "len" field,
                            if (std.mem.eql(u8, "len", path)) {
                                return try find(.Leaf, action_param, out_writer, data.len, path_iterator, index);
                            }
                        },

                        .Many => @compileError("[*] pointers not supported"),
                        .C => @compileError("[*c] pointers not supported"),
                    },
                    .Optional => |info| {
                        if (data) |value| {
                            return try recursiveFind(depth, info.child, action_param, out_writer, value, path, path_iterator, index);
                        }
                    },
                    .Array => {

                        //Slice supports the "len" field,
                        if (std.mem.eql(u8, "len", path)) {
                            return try find(.Leaf, action_param, out_writer, data.len, path_iterator, index);
                        }
                    },
                    else => {},
                }

                return if (depth == .Root) .NotFoundInContext else .ChainBroken;
            }

            inline fn seekField(
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
                        return try find(.Leaf, action_param, out_writer, @field(data, field.name), path_iterator, index);
                    }
                } else {
                    return if (depth == .Root) .NotFoundInContext else .ChainBroken;
                }
            }

            inline fn seekFunction(
                depth: Depth,
                comptime TValue: type,
                action_param: anytype,
                out_writer: anytype,
                data: anytype,
                path: []const u8,
                path_iterator: *std.mem.TokenIterator(u8),
                index: ?usize,
            ) TError!Result {
                _ = depth;
                _ = action_param;
                _ = out_writer;
                _ = data;
                _ = path;
                _ = path_iterator;
                _ = index;

                // Lambdas supported signatures
                // Functions that accepts a muttable *T can only be called from a reference

                const lambda_signatures = .{
                    fn () void,
                    fn (content: []const u8) void,
                    fn (elements: []const Element) void,
                    fn (allocator: Allocator) void,
                    fn (self: TValue) void,
                    fn (self: TValue, content: []const u8) void,
                    fn (self: TValue, elements: []const Element) void,
                    fn (self: TValue, allocator: Allocator) void,
                    fn (self: TValue, allocator: Allocator, content: []const u8) void,
                    fn (self: TValue, allocator: Allocator, elements: []const Element) void,
                    fn (self: *const TValue) void,
                    fn (self: *const TValue, content: []const u8) void,
                    fn (self: *const TValue, elements: []const Element) void,
                    fn (self: *const TValue, allocator: Allocator) void,
                    fn (self: *const TValue, allocator: Allocator, content: []const u8) void,
                    fn (self: *const TValue, allocator: Allocator, elements: []const Element) void,
                    fn (self: *TValue) void,
                    fn (self: *TValue, content: []const u8) void,
                    fn (self: *TValue, elements: []const Element) void,
                    fn (self: *TValue, allocator: Allocator) void,
                    fn (self: *TValue, allocator: Allocator, content: []const u8) void,
                    fn (self: *TValue, allocator: Allocator, elements: []const Element) void,
                };

                _ = lambda_signatures;

                @panic("not implemented");
            }

            inline fn iterateAt(
                action_param: anytype,
                out_writer: anytype,
                data: anytype,
                index: usize,
            ) TError!Result {
                switch (@typeInfo(@TypeOf(data))) {
                    .Struct => |info| {
                        if (info.is_tuple) {
                            inline for (info.fields) |_, i| {
                                if (index == i) {
                                    return Result{
                                        .Resolved = blk: {

                                            // Tuple fields can be a comptime value
                                            // We must convert it to a runtime type
                                            const Data = @TypeOf(data[i]);
                                            if (Data == comptime_int) {
                                                const RuntimeInt = if (data[i] > 0) std.math.IntFittingRange(0, data[i]) else std.math.IntFittingRange(data[i], 0);
                                                var runtime_value: RuntimeInt = data[i];
                                                break :blk try action_fn(action_param, out_writer, runtime_value);
                                            } else if (Data == comptime_float) {
                                                var runtime_value: f64 = data[i];
                                                break :blk try action_fn(action_param, out_writer, runtime_value);
                                            } else if (Data == @TypeOf(null)) {
                                                var runtime_value: ?u0 = null;
                                                break :blk try action_fn(action_param, out_writer, runtime_value);
                                            } else if (Data == void) {
                                                return .IteratorConsumed;
                                            } else {
                                                break :blk try action_fn(action_param, out_writer, data[i]);
                                            }
                                        },
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
                            Result{ .Resolved = try action_fn(action_param, out_writer, data) }
                        else
                            .IteratorConsumed;
                    },

                    .Pointer => |info| switch (info.size) {
                        .Slice => {

                            //Slice of u8 is always string
                            if (info.child != u8) {
                                return if (index < data.len)
                                    Result{ .Resolved = try action_fn(action_param, out_writer, data[index]) }
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
                                Result{ .Resolved = try action_fn(action_param, out_writer, data[index]) }
                            else
                                .IteratorConsumed;
                        }
                    },

                    .Optional => {
                        return if (data) |value|
                            try iterateAt(action_param, out_writer, value, index)
                        else
                            .IteratorConsumed;
                    },
                    else => {},
                }

                return if (index == 0)
                    Result{ .Resolved = try action_fn(action_param, out_writer, data) }
                else
                    .IteratorConsumed;
            }
        };
    }

    inline fn no_action(
        param: void,
        out_writer: anytype,
        value: anytype,
    ) @TypeOf(out_writer).Error!void {
        _ = param;
        _ = out_writer;
        _ = value;
    }

    inline fn stringify(
        escape: Escape,
        out_writer: anytype,
        value: anytype,
    ) @TypeOf(out_writer).Error!void {
        const typeInfo = @typeInfo(@TypeOf(value));

        switch (typeInfo) {
            .Void, .Null => {},

            // what should we print?
            .Struct, .Opaque => {},

            .Bool => return try escape_write(out_writer, if (value) "true" else "false", escape),
            .Int, .ComptimeInt => return try std.fmt.formatInt(value, 10, .lower, .{}, out_writer),
            .Float, .ComptimeFloat => return try std.fmt.formatFloatDecimal(value, .{}, out_writer),
            .Enum => return try escape_write(out_writer, @tagName(value), escape),

            .Pointer => |info| switch (info.size) {
                TypeInfo.Pointer.Size.One => return try stringify(escape, out_writer, value.*),
                TypeInfo.Pointer.Size.Slice => {
                    if (info.child == u8) {
                        return try escape_write(out_writer, value, escape);
                    }
                },
                TypeInfo.Pointer.Size.Many => @compileError("[*] pointers not supported"),
                TypeInfo.Pointer.Size.C => @compileError("[*c] pointers not supported"),
            },
            .Array => |info| {
                if (info.child == u8) {
                    return try escape_write(out_writer, &value, escape);
                }
            },
            .Optional => {
                if (value) |not_null| {
                    return try stringify(escape, out_writer, not_null);
                }
            },
            else => @compileError("Not supported"),
        }
    }

    fn escape_write(
        out_writer: anytype,
        value: []const u8,
        escape: Escape,
    ) @TypeOf(out_writer).Error!void {
        switch (escape) {
            .Unescaped => {
                try out_writer.writeAll(value);
            },

            .Escaped => {
                const @"null" = '\x00';
                const html_null: []const u8 = "\u{fffd}";

                var index: usize = 0;

                for (value) |char, char_index| {
                    const replace = switch (char) {
                        '"' => "&quot;",
                        '\'' => "&#39;",
                        '&' => "&amp;",
                        '<' => "&lt;",
                        '>' => "&gt;",
                        @"null" => html_null,
                        else => continue,
                    };

                    if (char_index > index) {
                        try out_writer.writeAll(value[index..char_index]);
                    }

                    try out_writer.writeAll(replace);
                    index = char_index + 1;
                    if (index == value.len) break;
                }

                if (index < value.len) {
                    try out_writer.writeAll(value[index..]);
                }
            },
        }
    }

    test "escape_write" {
        const allocator = testing.allocator;
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try escape_write(list.writer(), ">abc", .Escaped);
        try testing.expectEqualStrings("&gt;abc", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), "abc<", .Escaped);
        try testing.expectEqualStrings("abc&lt;", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), ">abc<", .Escaped);
        try testing.expectEqualStrings("&gt;abc&lt;", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), "ab&cd", .Escaped);
        try testing.expectEqualStrings("ab&amp;cd", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), ">ab&cd", .Escaped);
        try testing.expectEqualStrings("&gt;ab&amp;cd", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), "ab&cd<", .Escaped);
        try testing.expectEqualStrings("ab&amp;cd&lt;", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), ">ab&cd<", .Escaped);
        try testing.expectEqualStrings("&gt;ab&amp;cd&lt;", list.items);

        list.clearAndFree();

        try escape_write(list.writer(), ">ab&cd<", .Unescaped);
        try testing.expectEqualStrings(">ab&cd<", list.items);
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

        const FooCaller = Caller(error{}, bool, fooAction);

        fn fooAction(comptime TExpected: type, out_writer: anytype, value: anytype) error{}!bool {
            _ = out_writer;
            return TExpected == @TypeOf(value);
        }

        fn fooSeek(comptime TExpected: type, data: anytype, path: []const u8, index: ?usize) !FooCaller.Result {
            var path_iterator = std.mem.tokenize(u8, path, ".");
            return try FooCaller.call(TExpected, std.io.null_writer, data, &path_iterator, index);
        }

        fn expectFound(comptime TExpected: type, data: anytype, path: []const u8) !void {
            const value = try fooSeek(TExpected, data, path, null);
            try testing.expect(value == .Resolved);
            try testing.expect(value.Resolved == true);
        }

        fn expectNotFound(data: anytype, path: []const u8) !void {
            const value = try fooSeek(void, data, path, null);
            try testing.expect(value != .Resolved);
        }

        fn expectIterFound(comptime TExpected: type, data: anytype, path: []const u8, index: usize) !void {
            const value = try fooSeek(TExpected, data, path, index);
            try testing.expect(value == .Resolved);
            try testing.expect(value.Resolved == true);
        }

        fn expectIterNotFound(data: anytype, path: []const u8, index: usize) !void {
            const value = try fooSeek(void, data, path, index);
            try testing.expect(value != .Resolved);
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

test {
    _ = Comptime.tests;
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
        .indication = &person_1,
        .active = true,
        .additional_information = "someone was here",
    };

    fn write(out_writer: anytype, data: anytype, path: []const u8) anyerror!void {
        const allocator = testing.allocator;

        var ctx = try getContext(allocator, out_writer, data);
        defer ctx.deinit(allocator);

        _ = try ctx.write(path, .Unescaped);
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

        _ = try person_ctx.write("address.street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Address

        var address_ctx = switch (try person_ctx.get(allocator, "address")) {
            .Resolved => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        // Street

        var street_ctx = switch (try address_ctx.get(allocator, "street")) {
            .Resolved => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("", .Unescaped);
        try testing.expectEqualStrings("nearby", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".", .Unescaped);
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

        _ = try person_ctx.write("indication.address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Indication

        var indication_ctx = switch (try person_ctx.get(allocator, "indication")) {
            .Resolved => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer indication_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try indication_ctx.write("address.street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Address

        var address_ctx = switch (try indication_ctx.get(allocator, "address")) {
            .Resolved => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer address_ctx.deinit(allocator);

        list.clearAndFree();
        _ = try address_ctx.write("street", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        // Street

        var street_ctx = switch (try address_ctx.get(allocator, "street")) {
            .Resolved => |found| found,
            else => {
                try testing.expect(false);
                unreachable;
            },
        };
        defer street_ctx.deinit(allocator);

        list.clearAndFree();

        _ = try street_ctx.write("", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);

        list.clearAndFree();

        _ = try street_ctx.write(".", .Unescaped);
        try testing.expectEqualStrings("far away street", list.items);
    }

    test "Navigation NotFound" {
        const allocator = testing.allocator;

        // Person
        var person_ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer person_ctx.deinit(allocator);

        // Person.address
        var address_ctx = switch (try person_ctx.get(allocator, "address")) {
            .Resolved => |found| found,
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
            .Resolved => |found| found,
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
            .Resolved => |found| found,
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

        var writer = list.writer();

        // Person
        var ctx = try getContext(allocator, writer, person_2);
        defer ctx.deinit(allocator);

        var iterator = switch (ctx.iterator("items")) {
            .Resolved => |found| found,
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

        _ = try item_1.write("name", .Unescaped);
        try testing.expectEqualStrings("item 1", list.items);

        var item_2 = (try iterator.next(allocator)) orelse {
            try testing.expect(false);
            return;
        };
        defer item_2.deinit(allocator);

        list.clearAndFree();

        _ = try item_2.write("name", .Unescaped);
        try testing.expectEqualStrings("item 2", list.items);

        var no_more = try iterator.next(allocator);
        try testing.expect(no_more == null);
    }

    test "Iterator over bool" {
        const allocator = testing.allocator;

        // Person
        var ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = switch (ctx.iterator("active")) {
                .Resolved => |found| found,
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
                .Resolved => |found| found,
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
        var ctx = try getContext(allocator, std.io.null_writer, person_2);
        defer ctx.deinit(allocator);

        {
            // iterator over true
            var iterator = switch (ctx.iterator("additional_information")) {
                .Resolved => |found| found,
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
                .Resolved => |found| found,
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
