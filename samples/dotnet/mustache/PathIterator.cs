using System.Runtime.CompilerServices;

namespace mustache;

#region Documentation

/// <summary>
/// Iterates over the unmanaged struct Interop.Path
/// </summary>

#endregion Documentation
[SkipLocalsInit]
internal ref struct PathIterator
{
    #region Fields

    private unsafe readonly Interop.Path* path;
    private unsafe Interop.PathPart* part;
    public ReadOnlySpan<byte> partName;

	#endregion Fields

	#region Properties


	#region Documentation

	/// <summary>
	/// Index, in case of iterating over a section
	/// </summary>

	#endregion Documentation

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

	#region Documentation
	
    /// <summary>
	/// Returns true case it is the root path
	/// For example "a.b", returns true on "a" and false on "b"
	/// </summary>
	
    #endregion Documentation
	
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
        this.partName = ReadOnlySpan<byte>.Empty;
    }

    #endregion Constructor

    #region Methods

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public bool MoveNext()
    {
        unsafe
        {
            if (part == null)
            {
				partName = ReadOnlySpan<byte>.Empty;
                return false;
            }
            else
            {
				partName = new ReadOnlySpan<byte>(part->value, part->size);
                part = part->next;
                return true;
            }
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Reset()
    {
        unsafe
        {
            part = path->root;
            partName = ReadOnlySpan<byte>.Empty;
        }
    }

    #endregion Methods
}

