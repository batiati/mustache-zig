const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

pub fn RefCountedSlice(comptime options: TemplateOptions) type {
    return struct {
        slice: []const u8,
        ref_counter: RefCounter(options),
    };
}

pub fn RefCounter(comptime options: TemplateOptions) type {
    return if (options.isRefCounted()) RefCounterImpl else NoOpRefCounter;
}

const RefCounterImpl = struct {
    const Self = @This();

    const State = struct {
        counter: usize,
        buffer: []const u8,
    };

    pub const null_ref = Self{};

    state: ?*State = null,

    pub fn create(allocator: Allocator, buffer: []const u8) Allocator.Error!Self {
        const state = try allocator.create(State);
        state.* = .{
            .counter = 1,
            .buffer = buffer,
        };

        return Self{ .state = state };
    }

    pub fn ref(self: Self) Self {
        if (self.state) |state| {
            assert(state.counter != 0);
            state.counter += 1;
            return .{ .state = state };
        } else {
            return null_ref;
        }
    }

    pub fn unRef(self: *Self, allocator: Allocator) void {
        if (self.state) |state| {
            assert(state.counter != 0);
            self.state = null;
            state.counter -= 1;
            if (state.counter == 0) {
                allocator.free(state.buffer);
                allocator.destroy(state);
            }
        }
    }
};

const NoOpRefCounter = struct {
    const Self = @This();

    pub const null_ref = Self{};

    pub inline fn init(allocator: Allocator, buffer: []const u8) Allocator.Error!Self {
        _ = allocator;
        _ = buffer;
        return null_ref;
    }

    pub inline fn ref(self: Self) Self {
        _ = self;
        return null_ref;
    }

    pub inline fn unRef(self: Self, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const testing_options = TemplateOptions{
    .source = .{ .file = .{} },
    .output = .render,
};

test "ref and free" {
    const allocator = testing.allocator;

    // No defer here, should be freed by the ref_counter
    const some_text = try allocator.dupe(u8, "some text");

    var counter_1 = try RefCounter(testing_options).create(allocator, some_text);
    var counter_2 = counter_1.ref();
    var counter_3 = counter_2.ref();

    try testing.expect(counter_1.state != null);
    try testing.expect(counter_1.state.?.counter == 3);

    try testing.expect(counter_2.state != null);
    try testing.expect(counter_2.state.?.counter == 3);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 3);

    counter_1.unRef(allocator);

    try testing.expect(counter_1.state == null);

    try testing.expect(counter_2.state != null);
    try testing.expect(counter_2.state.?.counter == 2);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 2);

    counter_2.unRef(allocator);

    try testing.expect(counter_1.state == null);
    try testing.expect(counter_2.state == null);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 1);

    counter_3.unRef(allocator);

    try testing.expect(counter_1.state == null);
    try testing.expect(counter_2.state == null);
    try testing.expect(counter_3.state == null);
}
