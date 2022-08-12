using System.Runtime.InteropServices;
using System.Text;
using System.Collections;
using System.Runtime.CompilerServices;

namespace mustache;

#region Documentation

/// <summary>
/// Iterates over the unmanaged struct Interop.Path
/// </summary>

#endregion Documentation
[SkipLocalsInit]
internal struct PathIterator
{
    #region Fields
    private unsafe Interop.Path* path;
    private unsafe Interop.PathPart* part;

    #endregion Fields

    #region Properties

    public int? Index
    {
        get
        {
            unsafe
            {
                return path->has_index == 1 ? path->index : null;
            }
        }
    }

    public bool IsRoot
    {
        get
        {
            unsafe
            {
                return part == path->root;
            }
        }
    }

    #endregion Properties

    #region Constructor

    public unsafe PathIterator(Interop.Path* path)
    {
        this.path = path;
        this.part = path->root;
    }

    #endregion Constructor

    #region Methods

    // [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public string? GetNext()
    {
        unsafe
        {
            if (part == null) return null;

            var str = Encoding.UTF8.GetString(part->value, part->size);
            part = part->next;

            return str;
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Reset()
    {
        unsafe
        {
            part = path->root;
        }
    }

    #endregion Methods
}

