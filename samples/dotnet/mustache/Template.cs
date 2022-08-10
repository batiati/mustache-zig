namespace mustache;
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
    }

    private void Dispose(bool disposing)
    {
        if (disposing) GC.SuppressFinalize(this);

        if (this.Handle != IntPtr.Zero)
        {
            _ = Interop.mustache_free_template(this.Handle);
            this.Handle = IntPtr.Zero;
        }
    }

    #endregion IDisposable
}
