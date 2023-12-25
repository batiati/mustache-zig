const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;

const testing = std.testing;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;

/// Partials map from a comptime known type
/// It works like a HashMap, but can be initialized from a tuple, slice or Hashmap
pub fn PartialsMap(comptime TPartials: type, comptime comptime_options: RenderOptions) type {
    return struct {
        const Self = @This();

        pub const options: RenderOptions = comptime_options;

        pub const Template = switch (options) {
            .template => mustache.Template,
            .string, .file => []const u8,
        };

        pub fn isEmpty() bool {
            return TPartials == void or
                (mustache.isTuple(TPartials) and meta.fields(TPartials).len == 0);
        }

        allocator: if (options != .template and !isEmpty()) Allocator else void,
        partials: TPartials,

        pub usingnamespace switch (options) {
            .template => struct {
                pub fn init(partials: TPartials) Self {
                    return .{
                        .allocator = {},
                        .partials = partials,
                    };
                }
            },
            .string, .file => struct {
                pub fn init(allocator: Allocator, partials: TPartials) Self {
                    return .{
                        .allocator = if (comptime isEmpty()) {} else allocator,
                        .partials = partials,
                    };
                }
            },
        };

        pub fn get(self: Self, key: []const u8) ?Self.Template {
            comptime validatePartials();

            if (comptime isValidTuple()) {
                return self.getFromTuple(key);
            } else if (comptime isValidIndexable()) {
                return self.getFromIndexable(key);
            } else if (comptime isValidMap()) {
                return self.getFromMap(key);
            } else if (comptime isEmpty()) {
                return null;
            } else {
                unreachable;
            }
        }

        fn getFromTuple(self: Self, key: []const u8) ?Self.Template {
            comptime assert(isValidTuple());

            if (comptime isPartialsTupleElement(TPartials)) {
                return if (std.mem.eql(u8, self.partials.@"0", key)) self.partials.@"1" else null;
            } else {
                inline for (0..meta.fields(TPartials).len) |index| {
                    const item = self.partials[index];
                    if (std.mem.eql(u8, item.@"0", key)) return item.@"1";
                } else {
                    return null;
                }
            }
        }

        fn getFromIndexable(self: Self, key: []const u8) ?Self.Template {
            comptime assert(isValidIndexable());

            for (self.partials) |item| {
                if (std.mem.eql(u8, item[0], key)) return item[1];
            }

            return null;
        }

        inline fn getFromMap(self: Self, key: []const u8) ?Self.Template {
            comptime assert(isValidMap());
            return self.partials.get(key);
        }

        fn validatePartials() void {
            comptime {
                if (!isValidTuple() and !isValidIndexable() and !isValidMap() and !isEmpty()) @compileError(
                    std.fmt.comptimePrint(
                        \\Invalid Partials type.
                        \\Expected a HashMap or a tuple containing Key/Value pairs
                        \\Key="[]const u8" and Value="{s}"
                        \\Found: "{s}"
                    , .{ @typeName(Self.Template), @typeName(TPartials) }),
                );
            }
        }

        fn isValidTuple() bool {
            comptime {
                if (mustache.isTuple(TPartials)) {
                    if (isPartialsTupleElement(TPartials)) {
                        return true;
                    } else {
                        for (meta.fields(TPartials)) |field| {
                            if (!isPartialsTupleElement(field.type)) {
                                return false;
                            }
                        } else {
                            return true;
                        }
                    }
                }

                return false;
            }
        }

        fn isValidIndexable() bool {
            comptime {
                if (mustache.isIndexable(TPartials) and !mustache.isTuple(TPartials)) {
                    if (mustache.isSingleItemPtr(TPartials) and mustache.is(.Array)(meta.Child(TPartials))) {
                        const Array = meta.Child(TPartials);
                        return isPartialsTupleElement(meta.Child(Array));
                    } else {
                        return isPartialsTupleElement(meta.Child(TPartials));
                    }
                }

                return false;
            }
        }

        fn isPartialsTupleElement(comptime TElement: type) bool {
            comptime {
                if (mustache.isTuple(TElement)) {
                    const fields = meta.fields(TElement);
                    if (fields.len == 2 and mustache.isZigString(fields[0].type)) {
                        if (fields[1].type == Self.Template) {
                            return true;
                        } else {
                            return mustache.isZigString(fields[1].type) and mustache.isZigString(Self.Template);
                        }
                    }
                }
                return false;
            }
        }

        fn isValidMap() bool {
            comptime {
                if (mustache.is(.Struct)(TPartials) and mustache.hasDecls(TPartials, .{ "KV", "get" })) {
                    const KV = @field(TPartials, "KV");
                    if (mustache.is(.Struct)(KV) and mustache.hasFields(KV, .{ "key", "value" })) {
                        const kv: KV = undefined;
                        return mustache.isZigString(@TypeOf(kv.key)) and
                            (@TypeOf(kv.value) == Self.Template or
                            (mustache.isZigString(@TypeOf(kv.value)) and mustache.isZigString(Self.Template)));
                    }
                }

                return false;
            }
        }
    };
}

test "Map single tuple" {
    const key: []const u8 = "hello";
    const value: []const u8 = "{{hello}}world";
    const data = .{ key, value };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map single tuple - comptime value" {
    // TODO: Compiler segfaul
    if (true) return error.SkipZigTest;
    const data = .{ "hello", "{{hello}}world" };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map empty tuple" {
    const data = .{};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map void" {
    const data = {};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map multiple tuple" {
    const Tuple = struct { []const u8, []const u8 };
    const Data = struct { Tuple, Tuple };
    const data: Data = .{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map multiple tuple comptime" {
    // TODO: Compiler segfaul
    if (true) return error.SkipZigTest;
    const data = .{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map array" {
    const data = [_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map ref array" {
    const data = &[_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map slice" {
    const array = [_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };
    const data = array[0..];

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map hashmap" {
    var data = std.StringHashMap([]const u8).init(testing.allocator);
    defer data.deinit();

    try data.put("hello", "{{hello}}world");
    try data.put("hi", "{{hi}}there");

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}
