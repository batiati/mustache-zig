using System.Text;
using System.Runtime.InteropServices;

namespace mustache;
public static class Mustache
{
    public static Template CreateTemplate(string content)
    {
        unsafe
        {
            var bytes = Encoding.UTF8.GetBytes(content);
            fixed (byte* ptr = &bytes[0])
            {
                var ret = Interop.mustache_create_template(ptr, bytes.Length, out IntPtr handle);
                if (ret != Interop.Status.SUCCESS) throw new Exception("TODO");

                return new Template(handle);
            }
        }
    }

    public static string Render(Template template, object instance)
    {
        var context = new Context(instance);

        unsafe
        {
            var ret = Interop.mustache_render(template.Handle, context.GetUserData(), out byte* buffer, out int bufferLen);
            if (ret != Interop.Status.SUCCESS) throw new Exception("TODO");

            try
            {
                return Encoding.UTF8.GetString(buffer, bufferLen);
            }
            finally
            {
                Interop.mustache_free_buffer(buffer, bufferLen);
            }
        }
    }
}