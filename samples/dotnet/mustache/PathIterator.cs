using System.Runtime.InteropServices;
using System.Text;
using System.Collections;

namespace mustache;

#region Documentation

/// <summary>
/// Iterates over the unmanaged struct Interop.Path
/// </summary>

#endregion Documentation
internal class PathIterator
{
    #region Fields
    private int current = 0;
    private unsafe Interop.Path* path;

    #endregion Fields

    #region Properties

    public int? Index
    {
        get
        {
            unsafe
            {
                return path->has_index ? path->index : null;
            }
        }
    }

    #endregion Properties

    #region Constructor

    public unsafe PathIterator(Interop.Path* path)
    {
        current = 0;
        this.path = path;
    }


    #endregion Constructor

    #region Methods

    public string? GetNext()
    {
        unsafe
        {
            if (current >= path->path_size) return null;

            var pathPart = (Interop.PathPart*)(path->path + current);
            var str = Encoding.UTF8.GetString(pathPart->value, pathPart->size);
            current += 1;

            return str;
        }
    }

    public void Reset()
    {
        current = 0;
    }

    #endregion Methods
}

