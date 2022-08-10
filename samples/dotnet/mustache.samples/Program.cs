// See https://aka.ms/new-console-template for more information

public class Data
{
    public string? title;
    public string? body;
}

public class Program
{

    public static void Main()
    {
        const string template_text = "<title>{{title}}</title><h1>{{ title }}</h1><div>{{{body}}}</div>";
        using var templete = mustache.Mustache.CreateTemplate(template_text);
        var data = new Data
        {
            title = "Hello, Mustache!",
            body = "This is a really simple test of the rendering!",
        };

        Console.WriteLine(mustache.Mustache.Render(templete, data));

        var watcher = System.Diagnostics.Stopwatch.StartNew();
        for (int i = 0; i < 1_000_000; i++)
        {
            /*
            var t = mustache.Mustache.CreateTemplate(@"
<html>
    <head>
        <title>{{title}}</title>
    </head>
    <body>
        {{#posts}}
            <h1>{{title}}</h1>
            <em>{{date}}</em>
            <article>
                {{{body}}}
            </article>
        {{/posts}}
    </body>
</html>");

            t.Dispose();
*/
            _ = mustache.Mustache.Render(templete, data);
        }
        watcher.Stop();

        Console.WriteLine($"Total time {watcher.ElapsedMilliseconds}ms");
    }

}