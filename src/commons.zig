const std = @import("std");
const AllocationError = std.mem.Allocator.Error;

pub const MustacheError = error{
    StartingDelimiterMismatch,
    EndingDelimiterMismatch,
    UnexpectedEof,
    UnexpectedCloseSection,
    InvalidDelimiters,
    InvalidIdentifier,
};

pub const TemplateOptions = struct {
    delimiters: Delimiters = .{},
    error_on_missing_value: bool = false,
};

