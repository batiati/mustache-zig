namespace mustache;

#region Documentation

/// <summary>
/// Represents a parsed template, ready to be rendered
/// </summary>

#endregion Documentation

public class Template : IDisposable
{
    #region Properties
    public nint Handle { get; private set; }

    #endregion Properties

    #region Constructor

    internal Template(nint handle)
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

        if (this.Handle != 0)
        {
            _ = Interop.mustache_free_template(this.Handle);
            this.Handle = 0;
        }
    }

    #endregion IDisposable
}