using System.Runtime.InteropServices;
using System.Text;

namespace mustache;

#region Documentation

/// <summary>
/// Mustache templating system
/// </summary>

#endregion Documentation

public static class Mustache
{
    #region Methods

    public static Template CreateTemplate(string content)
    {
        unsafe
        {
            var bytes = Encoding.UTF8.GetBytes(content);
            fixed (byte* ptr = &bytes[0])
            {
                var ret = Interop.mustache_create_template(ptr, bytes.Length, out nint handle);
                if (ret != Interop.Status.SUCCESS) throw new Exception("TODO");

                return new Template(handle);
            }
        }
    }

    public static string Render(Template template, object instance)
    {
        using (var context = new Context(instance))
        {
            unsafe
            {
                var ret = Interop.mustache_render(template.Handle, context.GetUserData(), out nint buffer, out int bufferLen);
                if (ret != Interop.Status.SUCCESS) throw new Exception("TODO");

                var str = Marshal.PtrToStringUTF8(buffer, bufferLen);
                Interop.mustache_free_buffer(buffer, bufferLen);

                return str;
            }
        }
    }

    #endregion Methods
}