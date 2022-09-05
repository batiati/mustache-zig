const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = std.meta.trait;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;
const Element = mustache.Element;

const rendering = @import("rendering.zig");
const ContextType = rendering.ContextType;

const native_context = @import("contexts/native/context.zig");
const json_context = @import("contexts/json/context.zig");
const ffi_context = @import("contexts/ffi/context.zig");

pub const Fields = @import("Fields.zig");

pub fn PathResolution(comptime Payload: type) type {
    return union(enum) {
        /// The path could no be found on the current context
        /// This result indicates that the path should be resolved against the parent context
        /// For example:
        /// context = .{ name = "Phill" };
        /// path = "address"
        not_found_in_context,

        /// Parts of the path could not be found on the current context.
        /// This result indicates that the path is broken and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .address = .{ street = "Wall St, 50", } };
        /// path = "address.country"
        chain_broken,

        /// The path could be resolved against the current context, but the iterator was fully consumed
        /// This result indicates that the path is valid, but not to be rendered and should NOT be resolved against the parent context
        /// For example:
        /// context = .{ .visible = false  };
        /// path = "visible"
        iterator_consumed,

        /// The lambda could be resolved against the current context,
        /// The payload is the result returned by "action_fn"
        lambda: Payload,

        /// The field could be resolved against the current context
        /// The payload is the result returned by "action_fn"
        field: Payload,
    };
}

pub const Escape = enum {
    Escaped,
    Unescaped,
};

pub fn Context(comptime context_type: ContextType, comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {

    // The native context uses dynamic dispatch to resolve how to render each kind of struct and data-type
    // The json context uses static dispatch, once the JSON key-value is well known for any possible type
    return switch (context_type) {
        .native => native_context.ContextInterface(Writer, PartialsMap, options),
        .json => json_context.Context(Writer, PartialsMap, options),
        .ffi => ffi_context.Context(Writer, PartialsMap, options),
    };
}

pub fn ContextImpl(comptime context_type: ContextType, comptime Writer: type, comptime Data: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    if (comptime context_type != ContextType.fromData(Data)) @compileError("Unexpected context_type");

    return switch (context_type) {
        .native => native_context.ContextImpl(Writer, Data, PartialsMap, options),
        .json => json_context.Context(Writer, PartialsMap, options),
        .ffi => ffi_context.Context(Writer, PartialsMap, options),
    };
}

pub fn ContextIterator(comptime ContextInterface: type) type {
    return struct {
        const Iterator = @This();

        data: union(enum) {
            empty,
            lambda: ContextInterface,
            sequence: struct {
                context: *const ContextInterface,
                path: Element.Path,
                state: union(enum) {
                    fetching: struct {
                        item: ContextInterface,
                        index: usize,
                    },
                    finished,
                },

                fn fetch(self: @This(), index: usize) ?ContextInterface {
                    const result = self.context.get(self.path, index);

                    return switch (result) {
                        .field => |item| item,
                        .iterator_consumed => null,
                        else => unreachable,
                    };
                }
            },
        },

        pub fn initEmpty() Iterator {
            return .{
                .data = .empty,
            };
        }

        pub fn initLambda(lambda_ctx: ContextInterface) Iterator {
            return .{
                .data = .{
                    .lambda = lambda_ctx,
                },
            };
        }

        pub fn initSequence(parent_ctx: *const ContextInterface, path: Element.Path, item: ContextInterface) Iterator {
            return .{
                .data = .{
                    .sequence = .{
                        .context = parent_ctx,
                        .path = path,
                        .state = .{
                            .fetching = .{
                                .item = item,
                                .index = 0,
                            },
                        },
                    },
                },
            };
        }

        pub fn lambda(self: Iterator) ?ContextInterface {
            return switch (self.data) {
                .lambda => |item| item,
                else => null,
            };
        }

        pub fn truthy(self: Iterator) bool {
            switch (self.data) {
                .empty => return false,
                .lambda => return true,
                .sequence => |sequence| switch (sequence.state) {
                    .fetching => return true,
                    .finished => return false,
                },
            }
        }

        pub fn next(self: *Iterator) ?ContextInterface {
            switch (self.data) {
                .lambda, .empty => return null,
                .sequence => |*sequence| switch (sequence.state) {
                    .fetching => |current| {
                        const next_index = current.index + 1;
                        if (sequence.fetch(next_index)) |item| {
                            sequence.state = .{
                                .fetching = .{
                                    .item = item,
                                    .index = next_index,
                                },
                            };
                        } else {
                            sequence.state = .finished;
                        }

                        return current.item;
                    },
                    .finished => return null,
                },
            }
        }
    };
}

/// Context for a lambda call,
/// this type must be accept as parameter by any function intended to be used as a lambda
///
/// When a lambda is called, any children {{tags}} won't have been expanded yet - the lambda should do that on its own.
/// In this way you can implement transformations, filters or caching.
pub const LambdaContext = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    inner_text: []const u8,

    pub const VTable = struct {
        renderAlloc: fn (*const anyopaque, Allocator, []const u8) anyerror![]u8,
        render: fn (*const anyopaque, Allocator, []const u8) anyerror!void,
        write: fn (*const anyopaque, []const u8) anyerror!usize,
    };

    /// Renders a template against the current context
    /// Returns an owned mutable slice with the rendered text
    pub inline fn renderAlloc(self: LambdaContext, allocator: Allocator, template_text: []const u8) anyerror![]u8 {
        return try self.vtable.renderAlloc(self.ptr, allocator, template_text);
    }

    /// Formats a template to be rendered against the current context
    /// Returns an owned mutable slice with the rendered text
    pub fn renderFormatAlloc(self: LambdaContext, allocator: Allocator, comptime fmt: []const u8, args: anytype) anyerror![]u8 {
        const template_text = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(template_text);

        return try self.vtable.renderAlloc(self.ptr, allocator, template_text);
    }

    /// Renders a template against the current context
    /// Can return anyerror depending on the underlying writer
    pub inline fn render(self: LambdaContext, allocator: Allocator, template_text: []const u8) anyerror!void {
        try self.vtable.render(self.ptr, allocator, template_text);
    }

    /// Formats a template to be rendered against the current context
    /// Can return anyerror depending on the underlying writer
    pub fn renderFormat(self: LambdaContext, allocator: Allocator, comptime fmt: []const u8, args: anytype) anyerror!void {
        const template_text = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(template_text);

        try self.vtable.render(self.ptr, allocator, template_text);
    }

    /// Writes the raw text on the output stream.
    /// Can return anyerror depending on the underlying writer
    pub fn writeFormat(self: LambdaContext, comptime fmt: []const u8, args: anytype) anyerror!void {
        var writer = std.io.Writer(LambdaContext, anyerror, writeFn){
            .context = self,
        };

        try std.fmt.format(writer, fmt, args);
    }

    /// Writes the raw text on the output stream.
    /// Can return anyerror depending on the underlying writer
    pub fn write(self: LambdaContext, raw_text: []const u8) anyerror!void {
        _ = try self.vtable.write(self.ptr, raw_text);
    }

    fn writeFn(self: LambdaContext, bytes: []const u8) anyerror!usize {
        return try self.vtable.write(self.ptr, bytes);
    }
};

test {
    _ = Fields;
    _ = native_context;
    _ = json_context;
    _ = ffi_context;
}
