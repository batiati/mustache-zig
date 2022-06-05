const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;
const ParseError = mustache.ParseError;
const ParseErrorDetail = mustache.ParseErrorDetail;

const TemplateOptions = mustache.options.TemplateOptions;

const assert = std.debug.assert;
const testing = std.testing;

const parsing = @import("parsing.zig");
const Delimiters = parsing.Delimiters;
const PartType = parsing.PartType;
const FileReader = parsing.FileReader;

const ref_counter = @import("ref_counter.zig");

const parsePath = @import("../template.zig").parsePath;

pub fn Parser(comptime options: TemplateOptions, comptime prealoc_item_count: usize) type {
    const allow_lambdas = options.features.lambdas == .Enabled;
    const copy_string = options.copyStrings();

    return struct {
        pub const LoadError = Allocator.Error || if (options.source == .Stream) std.fs.File.ReadError || std.fs.File.OpenError else error{};
        pub const AbortError = error{ParserAbortedError};

        pub const Node = parsing.Node(options, prealoc_item_count);

        const TextScanner = parsing.TextScanner(Node, options);
        const TextPart = Node.TextPart;
        const RefCounter = ref_counter.RefCounter(options);

        fn RenderError(comptime TRender: type) type {
            switch (@typeInfo(TRender)) {
                .Pointer => |pointer| {
                    if (pointer.size == .One) {
                        const Render = pointer.child;
                        return Render.Error;
                    }
                },
                else => {},
            }

            @compileError("Expected a pointer to a Render");
        }

        const Self = @This();

        /// General purpose allocator
        gpa: Allocator,

        /// Produced nodes
        nodes: Node.List = undefined,

        /// Stores the last error ocurred parsing the content
        last_error: ?ParseErrorDetail = null,

        /// Default open/close delimiters
        default_delimiters: Delimiters,

        /// Parser's inner state
        inner_state: struct {
            text_scanner: TextScanner,
            last_static_text: ?*Node = null,
        },

        pub fn init(gpa: Allocator, template: []const u8, delimiters: Delimiters) if (options.source == .String) Allocator.Error!Self else FileReader(options).Error!Self {
            return Self{
                .gpa = gpa,
                .default_delimiters = delimiters,
                .inner_state = .{
                    .text_scanner = try TextScanner.init(gpa, template),
                },
            };
        }

        pub fn deinit(self: *Self) void {
            self.inner_state.text_scanner.deinit(self.gpa);
        }

        pub fn parse(self: *Self, render: anytype) (LoadError || RenderError(@TypeOf(render)))!bool {
            self.nodes = .{};
            defer self.nodes.deinit(self.gpa);

            self.beginLevel(0, self.default_delimiters, render) catch |err| switch (err) {
                AbortError.ParserAbortedError => return false,
                else => {
                    const Error = LoadError || RenderError(@TypeOf(render));
                    return @errSetCast(Error, err);
                },
            };

            return true;
        }

        fn beginLevel(self: *Self, level: u32, delimiters: Delimiters, render: anytype) (AbortError || LoadError || RenderError(@TypeOf(render)))!void {
            var current_delimiters = delimiters;

            const initial_index = self.nodes.len;

            if (self.inner_state.text_scanner.delimiter_max_size == 0) {
                self.inner_state.text_scanner.setDelimiters(current_delimiters) catch |err| {
                    return self.abort(err, null);
                };
            }

            while (try self.inner_state.text_scanner.next(self.gpa)) |*text_part| {
                switch (text_part.part_type) {
                    .static_text => {
                        // TODO: Static text must be ignored if inside a "parent" tag
                        // https://github.com/mustache/spec/blob/b2aeb3c283de931a7004b5f7a2cb394b89382369/specs/~inheritance.yml#L211
                    },

                    .comments => {
                        defer if (options.isRefCounted()) text_part.unRef(self.gpa);

                        // Comments are just ignored
                        self.checkIfLastNodeCanBeStandAlone(text_part.part_type);
                        continue;
                    },

                    .delimiters => {
                        defer if (options.isRefCounted()) text_part.unRef(self.gpa);

                        current_delimiters = try self.parseDelimiters(text_part);

                        self.inner_state.text_scanner.setDelimiters(current_delimiters) catch |err| {
                            return self.abort(err, text_part);
                        };

                        self.checkIfLastNodeCanBeStandAlone(text_part.part_type);

                        continue;
                    },

                    .close_section => {
                        defer if (options.isRefCounted()) text_part.unRef(self.gpa);

                        if (level == 0 or initial_index == 0) {
                            return self.abort(ParseError.UnexpectedCloseSection, text_part);
                        }

                        var open_node: *Node = self.nodes.at(initial_index - 1);
                        const open_identifier = open_node.identifier orelse return self.abort(ParseError.UnexpectedCloseSection, text_part);
                        const close_identifier = (try self.parseIdentifier(text_part)) orelse unreachable;

                        if (!std.mem.eql(u8, open_identifier, close_identifier)) {
                            return self.abort(ParseError.ClosingTagMismatch, text_part);
                        }

                        open_node.children_count = @intCast(u32, self.nodes.len - initial_index);

                        if (allow_lambdas and open_node.text_part.part_type == .section) {
                            if (try self.inner_state.text_scanner.endBookmark()) |bookmark| {
                                open_node.inner_text.content = bookmark;
                            }
                        }

                        self.checkIfLastNodeCanBeStandAlone(text_part.part_type);
                        return;
                    },

                    else => {},
                }

                // Adding
                var current_node = current_node: {
                    const index = @intCast(u32, self.nodes.len);
                    var ptr = try self.nodes.addOne(self.gpa);
                    ptr.* = Node{
                        .index = index,
                        .identifier = try self.parseIdentifier(text_part),
                        .text_part = text_part.*,
                        .delimiters = current_delimiters,
                    };

                    break :current_node ptr;
                };

                switch (current_node.text_part.part_type) {
                    .static_text => {
                        current_node.trimStandAlone(&self.nodes);
                        if (current_node.text_part.isEmpty()) {
                            current_node.text_part.unRef(self.gpa);
                            _ = self.nodes.pop();
                            continue;
                        }

                        self.inner_state.last_static_text = current_node;

                        // When options.output = .Render,
                        // A stand-alone line in the root level indicates that the previous produced nodes can be rendered
                        if (options.output == .Render) {
                            if (level == 0 and
                                current_node.text_part.trimming.left != .PreserveWhitespaces and
                                self.canProducePartialNodes())
                            {
                                // Remove the last node
                                const last_node_value = self.nodes.pop().?;

                                // Render all nodes produced until now
                                try self.produceNodes(render);

                                // Clean all nodes and reinsert the last one for the next iteration,
                                self.nodes.shrinkRetainingCapacity(0);

                                current_node = try self.nodes.addOne(self.gpa);
                                current_node.* = Node{
                                    .index = 0,
                                    .identifier = last_node_value.identifier,
                                    .text_part = last_node_value.text_part,
                                    .children_count = last_node_value.children_count,
                                    .inner_text = last_node_value.inner_text,
                                    .delimiters = last_node_value.delimiters,
                                };
                                self.inner_state.last_static_text = current_node;
                            }
                        }
                    },

                    .section,
                    .inverted_section,
                    .parent,
                    .block,
                    => {
                        if (allow_lambdas and current_node.text_part.part_type == .section) {
                            try self.inner_state.text_scanner.beginBookmark(current_node);
                        }

                        try self.beginLevel(level + 1, current_delimiters, render);

                        // Restore parent delimiters
                        self.inner_state.text_scanner.setDelimiters(current_delimiters) catch |err| {
                            return self.abort(err, &current_node.text_part);
                        };
                    },

                    else => {},
                }
            }

            if (level != 0) {
                return self.abort(ParseError.UnexpectedEof, null);
            }

            if (self.inner_state.last_static_text) |last_static_text| {
                last_static_text.trimLast(self.gpa, &self.nodes);
            }

            try self.produceNodes(render);
        }

        fn checkIfLastNodeCanBeStandAlone(self: *Self, part_type: PartType) void {
            if (self.nodes.len > 0) {
                var last_node = self.nodes.at(self.nodes.len - 1);
                last_node.text_part.is_stand_alone = part_type.canBeStandAlone();
            }
        }

        fn canProducePartialNodes(self: *const Self) bool {
            if (options.output == .Render) {
                const min_nodes = 2;
                if (self.nodes.len > min_nodes) {
                    var index: usize = 0;
                    const final_index = self.nodes.len - min_nodes;
                    while (index < final_index) : (index += 1) {
                        const node = self.nodes.at(index);
                        if (!node.text_part.isEmpty()) {
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        fn parseDelimiters(self: *Self, text_part: *const TextPart) AbortError!Delimiters {

            // Delimiters are the only case of match closing tags {{= and =}}
            // Validate if the content ends with the proper "=" symbol before parsing the delimiters
            var content = text_part.content.slice;
            const last_index = content.len - 1;
            if (content[last_index] != @enumToInt(PartType.delimiters)) return self.abort(ParseError.InvalidDelimiters, text_part);

            content = content[0..last_index];
            var iterator = std.mem.tokenize(u8, content, " \t");

            const starting_delimiter = iterator.next() orelse return self.abort(ParseError.InvalidDelimiters, text_part);
            const ending_delimiter = iterator.next() orelse return self.abort(ParseError.InvalidDelimiters, text_part);
            if (iterator.next() != null) return self.abort(ParseError.InvalidDelimiters, text_part);

            return Delimiters{
                .starting_delimiter = starting_delimiter,
                .ending_delimiter = ending_delimiter,
            };
        }

        fn parseIdentifier(self: *Self, text_part: *const TextPart) AbortError!?[]const u8 {
            switch (text_part.part_type) {
                .comments,
                .delimiters,
                .static_text,
                => return null,

                else => {
                    var tokenizer = std.mem.tokenize(u8, text_part.content.slice, " \t");
                    if (tokenizer.next()) |value| {
                        if (tokenizer.next() == null) {
                            return value;
                        }
                    }

                    return self.abort(ParseError.InvalidIdentifier, text_part);
                },
            }
        }

        fn abort(self: *Self, err: ParseError, text_part: ?*const TextPart) AbortError {
            self.last_error = ParseErrorDetail{
                .parse_error = err,
                .lin = if (text_part) |value| value.source.lin else 0,
                .col = if (text_part) |value| value.source.col else 0,
            };

            return AbortError.ParserAbortedError;
        }

        fn produceNodes(self: *Self, render: anytype) !void {
            if (self.nodes.len == 0) return;

            defer if (options.isRefCounted()) self.unRefNodes();

            var index: usize = 0;
            var buffer = try render.allocBuffer(self.nodes.len);

            defer if (comptime options.output == .Render) render.freeBuffer(buffer);
            defer if (comptime options.output == .Render) Element.deinitMany(self.gpa, copy_string, buffer[0..index]);

            errdefer if (comptime options.output == .Parse) render.freeBuffer(buffer);
            errdefer if (comptime options.output == .Parse) Element.deinitMany(self.gpa, copy_string, buffer[0..index]);

            var iterator = self.nodes.iterator(0);
            while (iterator.next()) |node| {
                if (!node.text_part.isEmpty()) {
                    buffer[index] = try self.createElement(node);
                    index += 1;
                }
            }

            try render.render(buffer[0..index]);
        }

        fn unRefNodes(self: *Self) void {
            if (options.isRefCounted()) {
                var iterator = self.nodes.iterator(0);
                while (iterator.next()) |node| {
                    node.unRef(self.gpa);
                }
            }
        }

        inline fn dupe(self: *Self, slice: []const u8) Allocator.Error![]const u8 {
            if (comptime copy_string) {
                return try self.gpa.dupe(u8, slice);
            } else {
                return slice;
            }
        }

        inline fn parsePath(self: *Self, identifier: []const u8) Allocator.Error!Element.Path {
            return try Element.createPath(self.gpa, copy_string, identifier);
        }

        fn createElement(self: *Self, node: *const Node) (AbortError || Allocator.Error)!Element {
            return switch (node.text_part.part_type) {
                .static_text => .{
                    .static_text = try self.dupe(node.text_part.content.slice),
                },

                else => |part_type| {
                    const allocator = self.gpa;
                    const identifier = node.identifier.?;

                    const indentation = if (node.getIndentation()) |node_indentation| try self.dupe(node_indentation) else null;
                    errdefer if (copy_string) if (indentation) |indentation_value| allocator.free(indentation_value);

                    const inner_text = if (node.getInnerText()) |inner_text_value| try self.dupe(inner_text_value) else null;
                    errdefer if (copy_string) if (inner_text) |inner_text_value| allocator.free(inner_text_value);

                    const children_count = node.children_count;

                    return switch (part_type) {
                        .interpolation => .{
                            .interpolation = try self.parsePath(identifier),
                        },
                        .unescaped_interpolation, .triple_mustache => .{
                            .unescaped_interpolation = try self.parsePath(identifier),
                        },
                        .inverted_section => .{
                            .inverted_section = .{
                                .path = try self.parsePath(identifier),
                                .children_count = children_count,
                            },
                        },
                        .section => .{
                            .section = .{
                                .path = try self.parsePath(identifier),
                                .children_count = children_count,
                                .inner_text = inner_text,
                                .delimiters = node.delimiters,
                            },
                        },
                        .partial => .{
                            .partial = .{
                                .key = try self.dupe(identifier),
                                .indentation = indentation,
                            },
                        },
                        .parent => .{
                            .parent = .{
                                .key = try self.dupe(identifier),
                                .children_count = children_count,
                                .indentation = indentation,
                            },
                        },
                        .block => .{
                            .block = .{
                                .key = try self.dupe(identifier),
                                .children_count = children_count,
                            },
                        },
                        else => unreachable,
                    };
                },
            };
        }
    };
}

const enable_comptime_tests = true;
const StreamedParser = Parser(.{ .source = .{ .String = .{} }, .output = .Render }, 32);
const DummyRender = struct {
    pub const Error = error{};

    buffer: [128]Element = undefined,

    pub inline fn allocBuffer(ctx: *@This(), size: usize) Allocator.Error![]Element {
        return ctx.buffer[0..size];
    }

    pub inline fn freeBuffer(ctx: *@This(), buffer: []Element) void {
        _ = ctx;
        _ = buffer;
    }

    pub fn render(ctx: *@This(), elements: []Element) Error!void {
        _ = ctx;
        _ = elements;
    }
};

test "Basic parse" {
    const template_text =
        \\{{! Comments block }}
        \\  Hello
        \\  {{#section}}
        \\Name: {{name}}
        \\Comments: {{&comments}}
        \\{{^inverted}}Inverted text{{/inverted}}
        \\{{/section}}
        \\World
    ;

    const TestRender = struct {
        pub const Error = error{ TestUnexpectedResult, TestExpectedEqual };

        calls: u32 = 0,
        buffer: [128]Element = undefined,

        pub inline fn allocBuffer(ctx: *@This(), size: usize) Allocator.Error![]Element {
            return ctx.buffer[0..size];
        }

        pub inline fn freeBuffer(ctx: *@This(), buffer: []Element) void {
            _ = ctx;
            _ = buffer;
        }

        pub fn render(ctx: *@This(), elements: []Element) Error!void {
            defer ctx.calls += 1;

            switch (ctx.calls) {
                0 => {
                    try testing.expectEqual(@as(usize, 10), elements.len);

                    {
                        const element = elements[0];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("  Hello\n", element.static_text);
                    }

                    {
                        const element = elements[1];
                        try testing.expectEqual(Element.Type.section, element);
                        try testing.expectEqualStrings("section", element.section.path[0]);
                        try testing.expectEqual(@as(u32, 8), element.section.children_count);
                    }

                    {
                        const element = elements[2];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("Name: ", element.static_text);
                    }

                    {
                        const element = elements[3];
                        try testing.expectEqual(Element.Type.interpolation, element);
                        try testing.expectEqualStrings("name", element.interpolation[0]);
                    }

                    {
                        const element = elements[4];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("\nComments: ", element.static_text);
                    }

                    {
                        const element = elements[5];
                        try testing.expectEqual(Element.Type.unescaped_interpolation, element);
                        try testing.expectEqualStrings("comments", element.unescaped_interpolation[0]);
                    }

                    {
                        const element = elements[6];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("\n", element.static_text);
                    }

                    {
                        const element = elements[7];
                        try testing.expectEqual(Element.Type.inverted_section, element);
                        try testing.expectEqualStrings("inverted", element.inverted_section.path[0]);
                        try testing.expectEqual(@as(u32, 1), element.inverted_section.children_count);
                    }

                    {
                        const element = elements[8];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("Inverted text", element.static_text);
                    }

                    {
                        const element = elements[9];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("\n", element.static_text);
                    }
                },
                1 => {
                    try testing.expectEqual(@as(usize, 1), elements.len);

                    {
                        const element = elements[0];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("World", element.static_text);
                    }
                },
                else => try testing.expect(false),
            }
        }
    };

    const runTheTest = struct {
        pub fn action() !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try StreamedParser.init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 2), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest();

    //Comptime test
    if (enable_comptime_tests) comptime {
        @setEvalBranchQuota(9999);
        try runTheTest();
    };
}

test "Scan standAlone tags" {
    const template_text =
        \\   {{!           
        \\   Comments block 
        \\   }}            
        \\Hello
    ;

    const TestRender = struct {
        pub const Error = error{ TestUnexpectedResult, TestExpectedEqual };

        calls: u32 = 0,
        buffer: [128]Element = undefined,

        pub inline fn allocBuffer(ctx: *@This(), size: usize) Allocator.Error![]Element {
            return ctx.buffer[0..size];
        }

        pub inline fn freeBuffer(ctx: *@This(), buffer: []Element) void {
            _ = ctx;
            _ = buffer;
        }

        pub fn render(ctx: *@This(), elements: []Element) Error!void {
            defer ctx.calls += 1;

            switch (ctx.calls) {
                0 => {
                    try testing.expectEqual(@as(usize, 1), elements.len);

                    {
                        var element = elements[0];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("Hello", element.static_text);
                    }
                },
                else => try testing.expect(false),
            }
        }
    };

    const runTheTest = struct {
        pub fn action() !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try StreamedParser.init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 1), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest();

    //Comptime test
    if (enable_comptime_tests) comptime {
        @setEvalBranchQuota(9999);
        try runTheTest();
    };
}

test "Scan delimiters Tags" {
    const template_text =
        \\{{=[ ]=}}           
        \\[interpolation.value]
    ;

    const TestRender = struct {
        pub const Error = error{ TestUnexpectedResult, TestExpectedEqual };

        calls: u32 = 0,
        buffer: [128]Element = undefined,

        pub inline fn allocBuffer(ctx: *@This(), size: usize) Allocator.Error![]Element {
            return ctx.buffer[0..size];
        }

        pub inline fn freeBuffer(ctx: *@This(), buffer: []Element) void {
            _ = ctx;
            _ = buffer;
        }

        pub fn render(ctx: *@This(), elements: []Element) Error!void {
            defer ctx.calls += 1;

            switch (ctx.calls) {
                0 => {
                    try testing.expectEqual(@as(usize, 1), elements.len);

                    {
                        var element = elements[0];
                        try testing.expectEqual(Element.Type.interpolation, element);
                        try testing.expectEqualStrings("interpolation", element.interpolation[0]);
                        try testing.expectEqualStrings("value", element.interpolation[1]);
                    }
                },
                else => try testing.expect(false),
            }
        }
    };

    const runTheTest = struct {
        pub fn action() !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try StreamedParser.init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 1), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest();

    //Comptime test
    if (enable_comptime_tests) comptime {
        @setEvalBranchQuota(9999);
        try runTheTest();
    };
}

test "Parse - UnexpectedCloseSection " {

    //                          Close section
    //                          ↓
    const template_text = "hello{{/section}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var render = DummyRender{};
    const success = try parser.parse(&render);

    try testing.expect(success == false);
    try testing.expect(parser.last_error != null);
    const err = parser.last_error.?;

    try testing.expectEqual(ParseError.UnexpectedCloseSection, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 6), err.col);
}

test "Parse - Invalid delimiter" {

    //                     Delimiter
    //                     ↓
    const template_text = "{{= not valid delimiter =}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var render = DummyRender{};
    const success = try parser.parse(&render);

    try testing.expect(success == false);
    try testing.expect(parser.last_error != null);
    const err = parser.last_error.?;

    try testing.expectEqual(ParseError.InvalidDelimiters, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 1), err.col);
}

test "Parse - Invalid identifier" {

    //                        Identifier
    //                        ↓
    const template_text = "Hi {{ not a valid identifier }}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var render = DummyRender{};
    const success = try parser.parse(&render);

    try testing.expect(success == false);
    try testing.expect(parser.last_error != null);
    const err = parser.last_error.?;

    try testing.expectEqual(ParseError.InvalidIdentifier, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 4), err.col);
}

test "Parse - ClosingTagMismatch " {

    //                                  Close section
    //                                  ↓
    const template_text = "{{#hello}}...{{/world}}";

    const allocator = testing.allocator;

    var parser = try StreamedParser.init(allocator, template_text, .{});
    defer parser.deinit();

    var render = DummyRender{};
    const success = try parser.parse(&render);

    try testing.expect(success == false);
    try testing.expect(parser.last_error != null);
    const err = parser.last_error.?;

    try testing.expectEqual(ParseError.ClosingTagMismatch, err.parse_error);
    try testing.expectEqual(@as(u32, 1), err.lin);
    try testing.expectEqual(@as(u32, 14), err.col);
}
