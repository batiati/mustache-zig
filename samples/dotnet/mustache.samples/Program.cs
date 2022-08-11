
public class Program
{
    // Mustache template
    const string template_text =

@"{{! This is a spec-compliant mustache template }}
Hello {{name}} from Zig
This template was generated with
{{#env}}
Zig: {{zig_version}}
Mustache: {{mustache_version}}
{{/env}}
Supported features:
{{#features}}
- {{name}} {{condition}}
{{/features}}";

    public class Feature
    {
        public string? name { get; set; }
        public string? condition { get; set; }
    }

    public class Env
    {
        public string? zig_version { get; set; }
        public string? mustache_version { get; set; }
    }

    public class Context
    {
        public string? name { get; set; }

        public Env? env { get; set; }

        public Feature[]? features { get; set; }
    }

    public class Data
    {
        public string? title;
        public string? body;
    }

    public static void Main()
    {
        Sample();
        BenchTest();
    }


    private static void Sample()
    {
        using var template = mustache.Mustache.CreateTemplate(template_text);

        // Context, can be any Zig struct, supporting optionals, slices, tuples, recursive types, pointers, etc.
        var ctx = new Context
        {
            name = "friends",
            env = new Env
            {
                zig_version = "master",
                mustache_version = "alpha",
            },
            features = new Feature[]
            {
                new Feature { name = "interpolation", condition = "✅ done" },
                new Feature { name = "sections", condition = "✅ done" },
                new Feature { name = "comments", condition = "✅ done" },
                new Feature { name = "delimiters", condition = "✅ done" },
                new Feature { name = "partials", condition = "✅ done" },
                new Feature { name = "lambdas", condition = "✅ done" },
                new Feature { name = "inheritance", condition = "⏳ comming soon" },
            },
        };

        Console.WriteLine(mustache.Mustache.Render(template, ctx));
    }


    private static void BenchTest()
    {
        using var templete = mustache.Mustache.CreateTemplate("<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>");
        var data = new Data
        {
            title = "Hello, Mustache!",
            body = "This is a really simple test of the rendering!",
        };

        Console.WriteLine("Rendering this simple template 1 million times\n{0}\n", mustache.Mustache.Render(templete, data));

        long total = 0;
        var watcher = System.Diagnostics.Stopwatch.StartNew();

        for (int i = 0; i < 1_000_000; i++)
        {
            var value = mustache.Mustache.Render(templete, data);
            total += value.Length;
        }
        watcher.Stop();

        Console.WriteLine($"C# FFI");
        Console.WriteLine($"Total time {watcher.Elapsed.TotalSeconds:0.000}s");
        Console.WriteLine($"{1_000_000d / watcher.Elapsed.TotalSeconds:0} ops/s");
        Console.WriteLine($"{watcher.ElapsedMilliseconds:0} ns/iter");
        Console.WriteLine($"{(total / 1024d / 10124d) / watcher.Elapsed.TotalSeconds:0} MB/s");
    }

}