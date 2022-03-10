# MUSTACHE-ZIG
[![made with Zig](https://img.shields.io/badge/made%20with%20%E2%9D%A4%20-Zig-orange)](https://ziglang.org/)
[![Docker Image CI](https://github.com/batiati/mustache-zig/actions/workflows/ci-codecov.yml/badge.svg)](https://github.com/batiati/mustache-zig/actions/workflows/ci-codecov.yml)
[![codecov](https://codecov.io/gh/batiati/mustache-zig/branch/master/graph/badge.svg)](https://codecov.io/gh/batiati/mustache-zig)
[![license mit](https://img.shields.io/github/license/batiati/mustache-zig)](https://github.com/batiati/mustache-zig/blob/master/LICENSE.txt)

Mustache-Zig is an implementation of the [{{mustache}} template system](https://mustache.github.io/) for [Zig](https://ziglang.org/).

![logo](mustache.png)

# ! Under development !

## Features

- [X] Comments `{{! Mustache is awesome }}`.
- [X] Custom delimiters `{{=[ ]=}}`.
- [X] Rendering common types, such as slices, arrays, tuples, enums, bools, optionals, pointers, integers and floats into `{{variables}`.
- [X] Unescaped interpolation with `{{{tripple-mustache}}}` or `{{&ampersant}}`.
- [X] Rendering sections `{{#foo}} ... {{/foo}}`.
- [X] Section iterator over slices, arrays and tuples `{{slice}} ... {{/slice}}`
- [X] Rendering inverse sections `{{^foo}} ... {{/foo}}`.
- [ ] Rendering partials `{{>file.html}}`.
- [ ] Rendering parents and blocks `{{<file.html}}` and `{{$block}}`.

## Full spec compliant

+ All implemented features passes the tests from [mustache spec](https://github.com/mustache/spec).

## Examples

Render from strings, files and pre-loaded templates.
See the [source code](https://github.com/batiati/mustache-zig/blob/master/samples/src/main.zig) for more details.

```Zig

const std = @import("std");
const mustache = @import("mustache");

pub fn main() !void {
    const template =
        \\Hello {{name}} from Zig
        \\Supported features:
        \\{{#features}}
        \\  - {{name}}
        \\{{/features}}
    ;

    var data = .{
        .name = "friends",
        .features = .{
            .{ .name = "interpolation" },
            .{ .name = "sections" },
            .{ .name = "delimiters" },
            .{ .name = "partials" },
        },
    };

    const allocator = std.testing.allocator;
    const result = try mustache.renderAllocFromString(allocator, template, data);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(
        \\Hello friends from Zig
        \\Supported features:
        \\  - interpolation
        \\  - sections
        \\  - delimiters
        \\  - partials
        \\
    , result);
}

```

## Benchmarks.

Mustache templates are well known for HTML templating, but it's useful to render any kind of dynamic document, and potentially load templates from untrusted or user-defined sources.

So, it's important to be able to deal with multi-megabyte inputs without eating all your RAM.

```Zig

    // 16KB should be enough memory for this job
    var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
        .requested_memory_limit = 16 * 1024,
    };
    defer _ = plenty_of_memory.deinit();

    try mustache.renderFromFile(plenty_of_memory.allocator(), "10MB_file.mustache", ctx, out_writer);

```

## Licensing

- MIT

- Mustache is Copyright (C) 2009 Chris Wanstrath
Original CTemplate by Google