const std = @import("std");
const meta = std.meta;
const trait = meta.trait;
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
            comptime {
                return TPartials == void or
                    (trait.isTuple(TPartials) and meta.fields(TPartials).len == 0);
            }
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
                inline for (meta.fields(TPartials)) |_, index| {
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
                if (trait.isTuple(TPartials)) {
                    if (isPartialsTupleElement(TPartials)) {
                        return true;
                    } else {
                        inline for (meta.fields(TPartials)) |field| {
                            if (!isPartialsTupleElement(field.field_type)) {
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
                if (trait.isIndexable(TPartials) and !trait.isTuple(TPartials)) {
                    if (trait.isSingleItemPtr(TPartials) and trait.is(.Array)(meta.Child(TPartials))) {
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
                if (trait.isTuple(TElement)) {
                    const fields = meta.fields(TElement);
                    if (fields.len == 2 and trait.isZigString(fields[0].field_type)) {
                        if (fields[1].field_type == Self.Template) {
                            return true;
                        } else {
                            return trait.isZigString(fields[1].field_type) and trait.isZigString(Self.Template);
                        }
                    }
                }
                return false;
            }
        }

        fn isValidMap() bool {
            comptime {
                if (trait.is(.Struct)(TPartials) and trait.hasDecls(TPartials, .{ "KV", "get" })) {
                    const KV = @field(TPartials, "KV");
                    if (trait.is(.Struct)(KV) and trait.hasFields(KV, .{ "key", "value" })) {
                        const kv: KV = undefined;
                        return trait.isZigString(@TypeOf(kv.key)) and
                            (@TypeOf(kv.value) == Self.Template or
                            (trait.isZigString(@TypeOf(kv.value)) and trait.isZigString(Self.Template)));
                    }
                }

                return false;
            }
        }
    };
}

test "Map single tuple" {
    var data = .{ "hello", "{{hello}}world" };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map empty tuple" {
    var data = .{};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map void" {
    var data = {};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMap(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map multiple tuple" {
    var data = .{
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
    const Tuple = meta.Tuple(&.{ []const u8, []const u8 });

    var data = [_]Tuple{
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
    const Tuple = meta.Tuple(&.{ []const u8, []const u8 });

    var data = &[_]Tuple{
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
    const Tuple = meta.Tuple(&.{ []const u8, []const u8 });
    const array = [_]Tuple{
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
