/// String and text manipulation helpers
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const assert = std.debug.assert;
const testing = std.testing;

pub const RefCounter = struct {
    pub const State = struct {
        counter: usize,
        buffer: []const u8,
    };

    state: ?*State = null,

    pub fn init(allocator: Allocator, buffer: []const u8) Allocator.Error!RefCounter {
        var state = try allocator.create(RefCounter.State);
        state.* = .{
            .counter = 1,
            .buffer = buffer,
        };

        return RefCounter{ .state = state };
    }

    pub fn ref(self: RefCounter) RefCounter {
        if (self.state) |state| {
            state.counter += 1;
            return .{ .state = state };
        } else {
            return .{};
        }
    }

    pub fn free(self: *RefCounter, allocator: Allocator) void {
        if (self.state) |state| {
            self.state = null;
            state.counter -= 1;
            if (state.counter == 0) {
                allocator.free(state.buffer);
                allocator.destroy(state);
            }
        }
    }
};

pub const RefCounterHolder = struct {
    group: std.AutoHashMapUnmanaged(usize, void) = .{},

    pub fn add(self: *RefCounterHolder, allocator: Allocator, ref_counter: RefCounter) Allocator.Error!void {
        if (ref_counter.state) |state| {
            var prev = try self.group.fetchPut(allocator, @ptrToInt(state), {});
            if (prev == null) {
                _ = ref_counter.ref();
            }
        }
    }

    pub fn remove(self: *RefCounterHolder, allocator: Allocator, ref_counter: *RefCounter) void {
        if (ref_counter.state) |state| {
            if (self.group.remove(@ptrToInt(state))) {
                ref_counter.free(allocator);
            }
        }
    }

    pub fn freeAll(self: *RefCounterHolder, allocator: Allocator) void {
        defer {
            self.group.deinit(allocator);
            self.group = .{};
        }

        var it = self.group.keyIterator();
        while (it.next()) |item| {
            var state = @intToPtr(*RefCounter.State, item.*);
            var ref_counter = RefCounter{ .state = state };
            ref_counter.free(allocator);
        }
    }
};

pub const EpochArena = struct {
    current_arena: ArenaAllocator,
    last_epoch_arena: ArenaAllocator.State,

    pub fn init(child_allocator: Allocator) EpochArena {
        return .{
            .current_arena = ArenaAllocator.init(child_allocator),
            .last_epoch_arena = .{},
        };
    }

    pub inline fn allocator(self: *EpochArena) Allocator {
        return self.current_arena.allocator();
    }

    pub fn nextEpoch(self: *EpochArena) void {
        const child_allocator = self.current_arena.child_allocator;

        var last_arena = self.last_epoch_arena.promote(child_allocator);
        last_arena.deinit();

        self.last_epoch_arena = self.current_arena.state;
        self.current_arena = ArenaAllocator.init(child_allocator);
    }

    pub fn deinit(self: *EpochArena) void {
        self.nextEpoch();
        self.nextEpoch();
    }
};
