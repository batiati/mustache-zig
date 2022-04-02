const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("mustache.zig");
const Options = mustache.options.Options;

pub fn RefCountedSlice(comptime options: Options) type {
    return struct {
        content: []const u8,
        ref_counter: RefCounter(options),
    };
}

pub fn RefCounter(comptime options: Options) type {
    return if (options.isRefCounted()) RefCounterImpl else NoOpRefCounter;
}

pub fn RefCounterHolder(comptime options: Options) type {
    return if (options.isRefCounted()) RefCounterHolderImpl else NoOpRefCounterHolder;
}

const RefCounterImpl = struct {
    const Self = @This();

    const State = struct {
        counter: u32,
        buffer: []const u8,
    };

    pub const null_ref = Self{};

    state: ?*State = null,

    pub fn init(allocator: Allocator, buffer: []const u8) Allocator.Error!Self {
        var state = try allocator.create(State);
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

    pub fn free(self: *Self, allocator: Allocator) void {
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

const RefCounterHolderImpl = struct {
    const Self = @This();
    const HashMap = std.AutoHashMapUnmanaged(usize, void);
    group: HashMap = .{},

    pub const Iterator = struct {
        hash_map_iterator: HashMap.KeyIterator,

        pub fn next(self: *Iterator) ?RefCounterImpl {
            return if (self.hash_map_iterator.next()) |item| blk: {
                var state = @intToPtr(*RefCounterImpl.State, item.*);
                break :blk RefCounterImpl{ .state = state };
            } else null;
        }
    };

    pub fn add(self: *Self, allocator: Allocator, ref_counter: RefCounterImpl) Allocator.Error!void {
        if (ref_counter.state) |state| {
            var prev = try self.group.fetchPut(allocator, @ptrToInt(state), {});
            if (prev == null) {
                _ = ref_counter.ref();
            }
        }
    }

    pub fn iterator(self: *const Self) Iterator {
        return Iterator{
            .hash_map_iterator = self.group.keyIterator(),
        };
    }

    pub fn free(self: *Self, allocator: Allocator) void {
        defer {
            self.group.deinit(allocator);
            self.group = .{};
        }

        var it = self.iterator();
        while (it.next()) |*ref_counter| {
            ref_counter.free(allocator);
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

    pub inline fn free(self: *Self, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

const NoOpRefCounterHolder = struct {
    const Self = @This();

    pub const Iterator = struct {
        pub fn next(self: *Iterator) ?NoOpRefCounter {
            _ = self;
            return null;
        }
    };

    pub inline fn add(self: *Self, allocator: Allocator, ref_counter: NoOpRefCounter) Allocator.Error!void {
        _ = self;
        _ = allocator;
        _ = ref_counter;
    }

    pub inline fn iterator(self: *const Self) Iterator {
        _ = self;
        return .{};
    }

    pub inline fn free(self: *Self, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub fn EpochArena(comptime options: Options) type {
    const is_epoch_arena = options.output == .Render;

    return struct {
        const Self = @This();

        current_arena: ArenaAllocator,
        last_epoch_arena: if (is_epoch_arena) ArenaAllocator.State else void,

        pub fn init(child_allocator: Allocator) Self {
            return .{
                .current_arena = ArenaAllocator.init(child_allocator),
                .last_epoch_arena = if (is_epoch_arena) .{} else {},
            };
        }

        pub inline fn allocator(self: *Self) Allocator {
            return self.current_arena.allocator();
        }

        pub fn nextEpoch(self: *Self) void {
            if (is_epoch_arena) {
                const child_allocator = self.current_arena.child_allocator;

                var last_arena = self.last_epoch_arena.promote(child_allocator);
                last_arena.deinit();

                self.last_epoch_arena = self.current_arena.state;
                self.current_arena = ArenaAllocator.init(child_allocator);
            }
        }

        pub fn deinit(self: *Self) void {
            if (is_epoch_arena) {
                var last_arena = self.last_epoch_arena.promote(self.current_arena.child_allocator);
                last_arena.deinit();
            }

            self.current_arena.deinit();
        }
    };
}

const testing_options = Options{
    .source = .{ .Stream = .{} },
    .output = .Render,
};

test "group" {
    const allocator = testing.allocator;

    // No defer here, should be freed by the ref_counter
    const some_text = try allocator.dupe(u8, "some text");

    var counter_1 = try RefCounter(testing_options).init(allocator, some_text);
    defer counter_1.free(allocator);

    var counter_2 = counter_1.ref();
    defer counter_2.free(allocator);

    var counter_3 = counter_2.ref();
    defer counter_3.free(allocator);

    try testing.expect(counter_1.state != null);
    try testing.expect(counter_1.state.?.counter == 3);

    try testing.expect(counter_2.state != null);
    try testing.expect(counter_2.state.?.counter == 3);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 3);

    var holder = RefCounterHolder(testing_options){};

    // Adding a ref_counter to the Holder, increases the counter
    try holder.add(allocator, counter_1);
    try testing.expect(counter_1.state.?.counter == 4);
    try testing.expect(counter_2.state.?.counter == 4);
    try testing.expect(counter_3.state.?.counter == 4);

    // Adding a ref_counter to the same buffer, keeps the counter unchanged
    try holder.add(allocator, counter_1);
    try holder.add(allocator, counter_2);
    try holder.add(allocator, counter_3);

    try testing.expect(counter_1.state.?.counter == 4);
    try testing.expect(counter_2.state.?.counter == 4);
    try testing.expect(counter_3.state.?.counter == 4);

    // Free should decrease the counter
    holder.free(allocator);

    try testing.expect(counter_1.state.?.counter == 3);
    try testing.expect(counter_2.state.?.counter == 3);
    try testing.expect(counter_3.state.?.counter == 3);
}

test "ref and free" {
    const allocator = testing.allocator;

    // No defer here, should be freed by the ref_counter
    const some_text = try allocator.dupe(u8, "some text");

    var counter_1 = try RefCounter(testing_options).init(allocator, some_text);
    var counter_2 = counter_1.ref();
    var counter_3 = counter_2.ref();

    try testing.expect(counter_1.state != null);
    try testing.expect(counter_1.state.?.counter == 3);

    try testing.expect(counter_2.state != null);
    try testing.expect(counter_2.state.?.counter == 3);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 3);

    counter_1.free(allocator);

    try testing.expect(counter_1.state == null);

    try testing.expect(counter_2.state != null);
    try testing.expect(counter_2.state.?.counter == 2);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 2);

    counter_2.free(allocator);

    try testing.expect(counter_1.state == null);
    try testing.expect(counter_2.state == null);

    try testing.expect(counter_3.state != null);
    try testing.expect(counter_3.state.?.counter == 1);

    counter_3.free(allocator);

    try testing.expect(counter_1.state == null);
    try testing.expect(counter_2.state == null);
    try testing.expect(counter_3.state == null);
}

test "epoch" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};

    var epoch_arena = EpochArena(testing_options).init(gpa.allocator());

    // First epoch,
    const arena = epoch_arena.allocator();
    var chunk = try arena.alloc(u8, 1024);
    const total_mem_1 = gpa.total_requested_bytes;
    try testing.expect(total_mem_1 >= chunk.len);

    // Second epoch, must keep previous epoch
    epoch_arena.nextEpoch();
    const new_arena = epoch_arena.allocator();
    var new_chunk = try new_arena.alloc(u8, 512);
    const total_mem_2 = gpa.total_requested_bytes;
    try testing.expect(total_mem_2 > total_mem_1);
    try testing.expect(total_mem_2 >= chunk.len + new_chunk.len);

    // Third epoch, must keep previous epoch and free the oldest one
    epoch_arena.nextEpoch();
    const total_mem_3 = gpa.total_requested_bytes;
    try testing.expect(total_mem_3 < total_mem_1);
    try testing.expect(total_mem_3 < total_mem_2);
    try testing.expect(total_mem_3 >= new_chunk.len);

    // Last epoch allocated nothing, so the total_mem must be zero
    epoch_arena.nextEpoch();
    const total_mem_4 = gpa.total_requested_bytes;
    try testing.expect(total_mem_4 == 0);
}
