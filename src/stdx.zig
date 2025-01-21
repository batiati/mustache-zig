const std = @import("std");

pub fn isSingleItemPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| return info.size == .one,
        else => false,
    };
}

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| return info.is_tuple,
        else => false,
    };
}

pub fn isIndexable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .one)
            isIndexable(std.meta.Child(T))
        else
            true,
        .array, .vector => true,
        else => isTuple(T),
    };
}

pub fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| return info.size == .slice,
        else => false,
    };
}

pub fn isIntegral(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => true,
        else => false,
    };
}

pub fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .comptime_float => true,
        else => false,
    };
}

pub fn isZigString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals
        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;

        const ptr = &info.pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .one) {
            const child = @typeInfo(ptr.child);
            if (child == .array) {
                const arr = &child.array;
                break :blk arr.child == u8;
            }
        }

        break :blk false;
    };
}

pub fn hasDecls(comptime T: type, comptime names: anytype) bool {
    inline for (names) |name| {
        if (!@hasDecl(T, name))
            return false;
    }
    return true;
}

pub fn hasFields(comptime T: type, comptime names: anytype) bool {
    inline for (names) |name| {
        if (!@hasField(T, name))
            return false;
    }
    return true;
}

pub inline fn canDeref(comptime TValue: type) bool {
    return isSingleItemPtr(TValue) and
        switch (@typeInfo(std.meta.Child(TValue))) {
        .@"fn", .@"opaque" => false,
        else => true,
    };
}
