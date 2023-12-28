const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const mustache = @import("../mustache.zig");
const Element = mustache.Element;
const ParseError = mustache.ParseError;
const ParseErrorDetail = mustache.ParseErrorDetail;

const TemplateOptions = mustache.options.TemplateOptions;
const TemplateLoadMode = mustache.options.TemplateLoadMode;

const assert = std.debug.assert;
const testing = std.testing;

const parsing = @import("parsing.zig");
const Delimiters = parsing.Delimiters;
const PartType = parsing.PartType;

const ref_counter = @import("ref_counter.zig");

pub fn ParserType(comptime options: TemplateOptions) type {
    const allow_lambdas = options.features.lambdas == .enabled;
    const copy_string = options.copyStrings();
    const is_comptime = options.load_mode == .comptime_loaded;

    return struct {
        const Parser = @This();

        pub const LoadError = Allocator.Error || if (options.source == .file) std.fs.File.ReadError || std.fs.File.OpenError else error{};
        pub const AbortError = error{ParserAbortedError};

        pub const Node = parsing.NodeType(options);

        const TextScanner = parsing.TextScannerType(Node, options);
        const FileReader = parsing.FileReaderType(options);
        const TextPart = Node.TextPart;
        const RefCounter = ref_counter.RefCounterType(options);
        const comptime_count = if (is_comptime) TextScanner.ComptimeCounter.count() else {};

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

        /// General purpose allocator
        gpa: Allocator,

        /// Stores the last error ocurred parsing the content
        last_error: ?ParseErrorDetail = null,

        /// Default open/close delimiters
        default_delimiters: Delimiters,

        /// Parser's inner state
        inner_state: struct {
            nodes: Node.List = undefined,
            text_scanner: TextScanner,
            last_static_text_node: ?u32 = null,
        },

        pub fn init(
            gpa: Allocator,
            template: []const u8,
            delimiters: Delimiters,
        ) if (options.source == .string)
            Allocator.Error!Parser
        else
            FileReader.OpenError!Parser {
            return Parser{
                .gpa = gpa,
                .default_delimiters = delimiters,
                .inner_state = .{
                    .text_scanner = try TextScanner.init(template),
                },
            };
        }

        pub fn deinit(self: *Parser) void {
            self.inner_state.text_scanner.deinit(self.gpa);
        }

        pub fn parse(
            self: *Parser,
            render: anytype,
        ) (LoadError || RenderError(@TypeOf(render)))!bool {
            self.inner_state.nodes = Node.List{};
            var nodes = &self.inner_state.nodes;

            self.inner_state.text_scanner.nodes = nodes;

            if (is_comptime) {
                comptime var buffer: [comptime_count.nodes]Node = undefined;
                nodes.items.ptr = &buffer;
                nodes.items.len = 0;
                nodes.capacity = buffer.len;
            } else {
                // Initializes with a small buffer
                // It gives a better performance for tiny templates and serves as hint for next resizes.
                const initial_capacity = 16;
                try nodes.ensureTotalCapacityPrecise(self.gpa, initial_capacity);
            }

            defer if (is_comptime) {
                nodes.clearRetainingCapacity();
            } else {
                nodes.deinit(self.gpa);
            };

            self.beginLevel(0, self.default_delimiters, render) catch |err| switch (err) {
                AbortError.ParserAbortedError => return false,
                else => {
                    const newerr: (LoadError || RenderError(@TypeOf(render))) = @errorCast(err);
                    return newerr;
                },
            };

            return true;
        }

        fn beginLevel(
            self: *Parser,
            level: u32,
            delimiters: Delimiters,
            render: anytype,
        ) (AbortError || LoadError || RenderError(@TypeOf(render)))!void {
            var current_delimiters = delimiters;

            var nodes = &self.inner_state.nodes;
            const initial_index = nodes.items.len;

            if (self.inner_state.text_scanner.delimiter_max_size == 0) {
                self.inner_state.text_scanner.setDelimiters(current_delimiters) catch |err| {
                    return self.abort(err, null);
                };
            }

            var produced_text_part: ?TextPart = try self.inner_state.text_scanner.next(self.gpa);
            while (produced_text_part) |*text_part| : (produced_text_part = try self.inner_state.text_scanner.next(self.gpa)) {
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

                        current_delimiters = text_part.parseDelimiters() orelse
                            return self.abort(ParseError.InvalidDelimiters, text_part);

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

                        var open_node: *Node = &nodes.items[initial_index - 1];
                        const open_identifier = open_node.identifier orelse
                            return self.abort(ParseError.UnexpectedCloseSection, text_part);
                        const close_identifier = (try self.parseIdentifier(text_part)) orelse unreachable;

                        if (!std.mem.eql(u8, open_identifier, close_identifier)) {
                            return self.abort(ParseError.ClosingTagMismatch, text_part);
                        }

                        open_node.children_count = @as(u32, @intCast(nodes.items.len - initial_index));

                        if (allow_lambdas and open_node.text_part.part_type == .section) {
                            if (try self.inner_state.text_scanner.endBookmark(nodes)) |bookmark| {
                                open_node.inner_text.content = bookmark;
                            }
                        }

                        self.checkIfLastNodeCanBeStandAlone(text_part.part_type);
                        return;
                    },

                    else => {},
                }

                // Adding
                var current_node: *Node = current_node: {
                    const index = @as(u32, @intCast(nodes.items.len));
                    const node = Node{
                        .index = index,
                        .identifier = try self.parseIdentifier(text_part),
                        .text_part = text_part.*,
                        .delimiters = current_delimiters,
                    };

                    if (is_comptime) {
                        nodes.appendAssumeCapacity(node);
                    } else {
                        try nodes.append(self.gpa, node);
                    }

                    break :current_node &nodes.items[index];
                };

                switch (current_node.text_part.part_type) {
                    .static_text => {
                        current_node.trimStandAlone(nodes);
                        if (current_node.text_part.isEmpty()) {
                            current_node.text_part.unRef(self.gpa);
                            _ = nodes.pop();
                            continue;
                        }

                        self.inner_state.last_static_text_node = current_node.index;

                        // When options.output = .render,
                        // A stand-alone line in the root level indicates that the previous produced nodes can be rendered
                        if (options.output == .render) {
                            if (level == 0 and
                                current_node.text_part.trimming.left != .preserve_whitespaces and
                                self.canProducePartialNodes())
                            {
                                // Remove the last node
                                const last_node_value = nodes.pop();

                                // Render all nodes produced until now
                                try self.produceNodes(render);

                                // Clean all nodes and reinsert the last one for the next iteration,
                                nodes.clearRetainingCapacity();

                                const node = Node{
                                    .index = 0,
                                    .identifier = last_node_value.identifier,
                                    .text_part = last_node_value.text_part,
                                    .children_count = last_node_value.children_count,
                                    .inner_text = last_node_value.inner_text,
                                    .delimiters = last_node_value.delimiters,
                                };

                                nodes.appendAssumeCapacity(node);
                                current_node = &nodes.items[0];

                                self.inner_state.last_static_text_node = current_node.index;
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

            if (self.inner_state.last_static_text_node) |last_static_text_node_index| {
                var last_static_text_node: *Node = &nodes.items[last_static_text_node_index];
                last_static_text_node.trimLast(self.gpa, nodes);
            }

            try self.produceNodes(render);
        }

        fn checkIfLastNodeCanBeStandAlone(self: *Parser, part_type: PartType) void {
            var nodes = &self.inner_state.nodes;
            if (nodes.items.len > 0) {
                var last_node: *Node = &nodes.items[nodes.items.len - 1];
                last_node.text_part.is_stand_alone = part_type.canBeStandAlone();
            }
        }

        fn canProducePartialNodes(self: *const Parser) bool {
            if (options.output == .render) {
                var nodes = &self.inner_state.nodes;
                const min_nodes = 2;
                if (nodes.items.len > min_nodes) {
                    var index: usize = 0;
                    const final_index = nodes.items.len - min_nodes;
                    while (index < final_index) : (index += 1) {
                        const node: *const Node = &nodes.items[index];
                        if (!node.text_part.isEmpty()) {
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        fn parseIdentifier(self: *Parser, text_part: *const TextPart) AbortError!?[]const u8 {
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

        fn abort(self: *Parser, err: ParseError, text_part: ?*const TextPart) AbortError {
            self.last_error = ParseErrorDetail{
                .parse_error = err,
                .lin = if (text_part) |value| value.source.lin else 0,
                .col = if (text_part) |value| value.source.col else 0,
            };

            return AbortError.ParserAbortedError;
        }

        fn produceNodes(self: *Parser, render: anytype) !void {
            const nodes = &self.inner_state.nodes;
            if (nodes.items.len == 0) return;

            defer if (options.isRefCounted()) self.unRefNodes();

            var list: std.ArrayListUnmanaged(Element) = .{};

            if (options.load_mode == .runtime_loaded) {
                try list.ensureTotalCapacityPrecise(self.gpa, nodes.items.len);
            } else {
                var buffer: [comptime_count.nodes]Element = undefined;
                list.items.ptr = &buffer;
                list.items.len = 0;
                list.capacity = buffer.len;
            }

            defer if (options.load_mode == .runtime_loaded) {

                // Clean up any elements left,
                // Both in case of error during the creation, or in case of output == .Render
                Element.deinitMany(self.gpa, copy_string, list.items);
                list.deinit(self.gpa);
            };

            for (nodes.items) |*node| {
                if (!node.text_part.isEmpty()) {
                    list.appendAssumeCapacity(try self.createElement(node));
                }
            }

            const elements = if (options.output == .render or options.load_mode == .comptime_loaded) list.items else try list.toOwnedSlice(self.gpa);
            try render.render(elements);
        }

        fn unRefNodes(self: *Parser) void {
            if (options.isRefCounted()) {
                const nodes = &self.inner_state.nodes;
                for (nodes.items) |*node| {
                    node.unRef(self.gpa);
                }
            }
        }

        inline fn dupe(self: *Parser, slice: []const u8) Allocator.Error![]const u8 {
            if (comptime copy_string) {
                return try self.gpa.dupe(u8, slice);
            } else {
                return slice;
            }
        }

        pub fn parsePath(self: *Parser, identifier: []const u8) Allocator.Error!Element.Path {
            const action = struct {
                pub fn action(ctx: *Parser, iterator: *std.mem.TokenIterator(u8, .any), index: usize) Allocator.Error!?[][]const u8 {
                    if (iterator.next()) |part| {
                        var path = (try action(ctx, iterator, index + 1)) orelse unreachable;
                        path[index] = try ctx.dupe(part);
                        return path;
                    } else {
                        if (comptime options.load_mode == .comptime_loaded) {
                            if (index == 0) {
                                return null;
                            } else {
                                // Creates a static buffer only if running at comptime
                                const buffer_len = comptime_count.path;
                                assert(buffer_len >= index);
                                var buffer: [buffer_len][]const u8 = undefined;
                                return buffer[0..index];
                            }
                        } else {
                            if (index == 0) {
                                return null;
                            } else {
                                return try ctx.gpa.alloc([]const u8, index);
                            }
                        }
                    }
                }
            }.action;

            const empty: Element.Path = &[0][]const u8{};

            if (identifier.len == 0) {
                return empty;
            } else {
                const path_separator = ".";
                var iterator = std.mem.tokenize(u8, identifier, path_separator);
                return (try action(self, &iterator, 0)) orelse empty;
            }
        }

        fn createElement(self: *Parser, node: *const Node) (AbortError || Allocator.Error)!Element {
            return switch (node.text_part.part_type) {
                .static_text => .{
                    .static_text = try self.dupe(node.text_part.content.slice),
                },

                else => |part_type| {
                    const identifier = node.identifier.?;
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
                        .section => section: {
                            const inner_text = if (node.getInnerText()) |inner_text_value|
                                try self.dupe(inner_text_value)
                            else
                                null;

                            break :section .{
                                .section = .{
                                    .path = try self.parsePath(identifier),
                                    .children_count = children_count,
                                    .inner_text = inner_text,
                                    .delimiters = node.delimiters,
                                },
                            };
                        },
                        .partial => partial: {
                            const indentation = if (node.getIndentation()) |node_indentation|
                                try self.dupe(node_indentation)
                            else
                                null;

                            break :partial .{
                                .partial = .{
                                    .key = try self.dupe(identifier),
                                    .indentation = indentation,
                                },
                            };
                        },
                        .parent => parent: {
                            const indentation = if (node.getIndentation()) |node_indentation|
                                try self.dupe(node_indentation)
                            else
                                null;

                            break :parent .{
                                .parent = .{
                                    .key = try self.dupe(identifier),
                                    .children_count = children_count,
                                    .indentation = indentation,
                                },
                            };
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

const comptime_tests_enabled = @import("build_comptime_tests").comptime_tests_enabled;
fn TesterParserType(comptime load_mode: TemplateLoadMode) type {
    return ParserType(.{ .source = .{ .string = .{} }, .output = .render, .load_mode = load_mode });
}

const DummyRender = struct {
    pub const Error = error{};

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
        pub fn action(comptime load_mode: TemplateLoadMode) !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try TesterParserType(load_mode).init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 2), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest(.runtime_loaded);

    //Comptime test
    if (comptime_tests_enabled) comptime {
        @setEvalBranchQuota(9999);
        try runTheTest(.{
            .comptime_loaded = .{
                .template_text = template_text,
                .default_delimiters = .{},
            },
        });
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

        pub fn render(ctx: *@This(), elements: []Element) Error!void {
            defer ctx.calls += 1;

            switch (ctx.calls) {
                0 => {
                    try testing.expectEqual(@as(usize, 1), elements.len);

                    {
                        const element = elements[0];
                        try testing.expectEqual(Element.Type.static_text, element);
                        try testing.expectEqualStrings("Hello", element.static_text);
                    }
                },
                else => try testing.expect(false),
            }
        }
    };

    const runTheTest = struct {
        pub fn action(comptime load_mode: TemplateLoadMode) !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try TesterParserType(load_mode).init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 1), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest(.runtime_loaded);

    //Comptime test
    if (comptime_tests_enabled) comptime {
        @setEvalBranchQuota(9999);
        try runTheTest(.{
            .comptime_loaded = .{
                .template_text = template_text,
                .default_delimiters = .{},
            },
        });
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

        pub fn render(ctx: *@This(), elements: []Element) Error!void {
            defer ctx.calls += 1;

            switch (ctx.calls) {
                0 => {
                    try testing.expectEqual(@as(usize, 1), elements.len);

                    {
                        const element = elements[0];
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
        pub fn action(comptime load_mode: TemplateLoadMode) !void {
            const allocator = testing.allocator;

            var test_render = TestRender{};
            var parser = try TesterParserType(load_mode).init(allocator, template_text, .{});
            defer parser.deinit();

            const success = try parser.parse(&test_render);

            try testing.expect(success);
            try testing.expectEqual(@as(u32, 1), test_render.calls);
        }
    }.action;

    //Runtime test
    try runTheTest(.runtime_loaded);

    //Comptime test
    if (comptime_tests_enabled) comptime {
        @setEvalBranchQuota(99999);
        try runTheTest(.{
            .comptime_loaded = .{
                .template_text = template_text,
                .default_delimiters = .{},
            },
        });
    };
}

test "Parse - UnexpectedCloseSection " {

    //                          Close section
    //                          ↓
    const template_text = "hello{{/section}}";

    const allocator = testing.allocator;

    // Cannot test parser errors at comptime because they generate compile errors.Allocator
    // This test can only run at runtime
    var parser = try TesterParserType(.runtime_loaded).init(allocator, template_text, .{});
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

    // Cannot test parser errors at comptime because they generate compile errors.Allocator
    // This test can only run at runtime
    var parser = try TesterParserType(.runtime_loaded).init(allocator, template_text, .{});
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

    // Cannot test parser errors at comptime because they generate compile errors.Allocator
    // This test can only run at runtime
    var parser = try TesterParserType(.runtime_loaded).init(allocator, template_text, .{});
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

    // Cannot test parser errors at comptime because they generate compile errors.Allocator
    // This test can only run at runtime
    var parser = try TesterParserType(.runtime_loaded).init(allocator, template_text, .{});
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
