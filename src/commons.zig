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

pub const Delimiters = struct {
    pub const DefaultStartingDelimiter = "{{";
    pub const DefaultEndingDelimiter = "}}";
    pub const NoScapeStartingDelimiter = "{{{";
    pub const NoScapeEndingDelimiter = "}}}";

    starting_delimiter: []const u8 = DefaultStartingDelimiter,
    ending_delimiter: []const u8 = DefaultEndingDelimiter,
};

pub const TemplateOptions = struct {
    delimiters: Delimiters = .{},
    error_on_missing_value: bool = false,
};
