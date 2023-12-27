# Lambdas

From [The Manual](https://mustache.github.io/mustache.5.html):

>When the value is a callable object, such as a function or lambda, the object will be invoked and passed the block of text. The text passed is the literal block, >unrendered. {{tags}} will not have been expanded - the lambda should do that on its own. In this way you can implement filters or caching.

Lambdas functions are intended to expand the template, not to be `getters` for fields.


## Lambda Context

Every lambda function must receive a `LambdaContext` parameter, for example, the `hash` function: 

```Zig
const Header = struct {
    id: u32,
    content: []const u8,

    pub fn hash(ctx: LambdaContext) !void {
        var content = try ctx.renderAlloc(ctx.allocator, ctx.inner_text);
        defer ctx.allocator.free(content);

        const hash_value = std.hash.Crc32.hash(content);

        try ctx.writeFormat("{}", .{hash_value});
    }
};
```

With lambdas, you can decouple the template from the data source in many possible ways.
In this example, the `hash` function is unaware of which fields are included on the hash.

```Zig
const template_text = "<header id='{{id}}' hash='{{#hash}}{{id}}{{content}}{{/hash}}'/>";

var header = Header{ .id = 100, .content = "This is some content" };
try expectRender(template_text, header, "<header id='100' hash='4174482081'/>");
```


### Data Context

Lambda functions can be called with [dot syntax](https://ziglang.org/documentation/master/#toc-struct), but they have to match the same mutability of the context. For example, let's say you have the following type:


```Zig
const Person = struct {
    first_name: []const u8,
    last_name: []const u8,

    pub fn name1(self: *Person, ctx: LambdaContext) !void {
        try ctx.writeFormat("{s} {s}", .{ self.first_name, self.last_name });
    }

    pub fn name2(self: Person, ctx: LambdaContext) !void {
        try ctx.writeFormat("{s} {s}", .{ self.first_name, self.last_name });
    }
};
```

While they appear to be identical functions, `name1` receives a mutable pointer parameter, and `name2` receives a value parameter.
Contexts of type `Person` and `*const Person` can only access `name2`, while contexts of type `*Person` can access both.

```Zig
const template_text = "Name1: {{name1}}, Name2: {{name2}}";
var data = Person { .first_name = "John", .last_name = "Smith" };

// By value
try expectRender(template_text, data, "Name1: , Name2: John Smith");

// By mutable pointer                        
try expectRender(template_text, &data, "Name1: John Smith, Name2: John Smith");

```