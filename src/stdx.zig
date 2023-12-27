const std = @import("std");

pub fn isSingleItemPtr(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |info| return info.size == .One,
        else => false,
    };
}

pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Struct => |info| return info.is_tuple,
        else => false,
    };
}

pub fn isIndexable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |info| if (info.size == .One)
            isIndexable(std.meta.Child(T))
        else
            true,
        .Array, .Vector => true,
        else => isTuple(T),
    };
}

pub fn isSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |info| return info.size == .Slice,
        else => false,
    };
}

pub fn isIntegral(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt => true,
        else => false,
    };
}

pub fn isFloat(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => true,
        else => false,
    };
}

pub fn isZigString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals
        const info = @typeInfo(T);
        if (info != .Pointer) break :blk false;

        const ptr = &info.Pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .Slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .One) {
            const child = @typeInfo(ptr.child);
            if (child == .Array) {
                const arr = &child.Array;
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
        .Fn, .Opaque => false,
        else => true,
    };
}
