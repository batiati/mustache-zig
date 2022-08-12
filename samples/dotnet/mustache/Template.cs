namespace mustache;

#region Documentation

/// <summary>
/// Represents a parsed template, ready to be rendered
/// </summary>

#endregion Documentation

public class Template : IDisposable
{
    #region Properties
    internal unsafe void* template;

    #endregion Properties

    #region Constructor

    internal unsafe Template(void* template)
    {
        this.template = template;
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

        unsafe
        {
            if (template != null)
            {
                _ = Interop.mustache_free_template(template);
                template = null;
            }
        }
    }

    #endregion IDisposable
}
