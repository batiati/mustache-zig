namespace mustache;

#region Documentation

/// <summary>
/// Represents a parsed template, ready to be rendered
/// </summary>

#endregion Documentation

public class Template : IDisposable
{
    #region Properties
    public IntPtr Handle { get; private set; }

    #endregion Properties

    #region Constructor

    internal Template(IntPtr handle)
    {
        Handle = handle;
    }

    ~Template()
    {
        Dispose(false);
    }

    #endregion Constructor

    #region IDisposable

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }

    private void Dispose(bool disposing)
    {
        _ = disposing;

        if (this.Handle != IntPtr.Zero)
        {
            _ = Interop.mustache_free_template(this.Handle);
            this.Handle = IntPtr.Zero;
        }
    }

    #endregion IDisposable
}
