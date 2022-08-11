using System.Runtime.InteropServices;
using System.Collections;
using System.Runtime.CompilerServices;
using static mustache.Interop;
using System.Text;

namespace mustache;

#region Documentation

/// <summary>
/// Represents a context being evaluated
/// </summary>

#endregion Documentation

internal sealed class Context : IDisposable
{
    #region Fields

    private Context? parent;
    private List<IntPtr>? handlers;

    #endregion Fields

    #region Properties

    public object Instance { get; private set; }

    #endregion Properties

    #region Constructor

    public Context(object instance)
    {
        this.Instance = instance;
        this.parent = null;
        this.handlers = new List<IntPtr>(64);
    }

    private Context(object instance, Context parent)
    {
        this.Instance = instance;
        this.parent = parent;
        this.handlers = null;
    }

    #endregion Constructor

    #region Methods

    private IntPtr GetHandle()
    {
        var handle = (IntPtr)GCHandle.Alloc(this, GCHandleType.Weak);

        var list = handlers ?? parent?.handlers;
        list!.Add(handle);

        return handle;
    }

    public UserData GetUserData()
    {
        unsafe
        {
			return new UserData
			{
				handle = GetHandle(),
				get = &Get,
				capacityHint = &CapacityHint,
				interpolate = &Interpolate,
				expandLambda = &ExpandLambda,
			};
        }
    }

    private static Context? GetContext(IntPtr handle)
    {
        return GCHandle.FromIntPtr(handle).Target as Context;
    }

    private unsafe static PathResolution ResolvePath(Interop.Path* path, ref object? instance)
    {
        var it = new PathIterator(path);
        while (it.GetNext() is string name)
        {
            if (instance is IDictionary dictionary)
            {
                instance = dictionary.Contains(name) ? dictionary[name] : null;
            }
            else if (instance != null)
            {
                instance = TypeDescriptor.Get(instance, name);
            }

            if (instance == null) break;
        }

        if (it.Index is int index)
        {
            if (instance is bool value)
            {
                if (value == false || index > 0) return Interop.PathResolution.ITERATOR_CONSUMED;
            }
            else if (instance is IList list)
            {
                if (index >= list.Count)
                {
                    return Interop.PathResolution.ITERATOR_CONSUMED;
                }
                else
                {
                    instance = list[index];
                }
            }
            else if (index > 0)
            {
                return Interop.PathResolution.ITERATOR_CONSUMED;
            }
        }

        return instance == null ? Interop.PathResolution.CHAIN_BROKEN : Interop.PathResolution.FIELD;
    }

    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution Get
    (
        IntPtr userDataHandle, 
        Interop.Path* path, 
        UserData* out_value
    )
    {
        var context = GetContext(userDataHandle);
        if (context == null) return Interop.PathResolution.CHAIN_BROKEN;

        var instance = context.Instance;
        var ret = ResolvePath(path, ref instance);

        if (instance != null)
        {
            var nextContext = new Context(instance, context);
            *out_value = nextContext.GetUserData();
        }

        return ret;
    }

    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution CapacityHint
    (
        IntPtr userDataHandle, 
        Interop.Path* path, 
        int* out_value
    )
    {
        var context = GetContext(userDataHandle);
        if (context == null) return PathResolution.CHAIN_BROKEN;

        var instance = context.Instance;
        var ret = ResolvePath(path, ref instance);

        if (instance != null)
        {
            const int NUMBER_HINT = 16;

            *out_value = instance switch
            {
                string str => str.Length,
                bool => 5,
                int => NUMBER_HINT,
                long => NUMBER_HINT,
                float => NUMBER_HINT,
                double => NUMBER_HINT,
                decimal => NUMBER_HINT,
                _ => 0,
            };
        }

        return ret;
    }

    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution Interpolate
    (
        IntPtr writerHandle,
        delegate* unmanaged[Cdecl]<IntPtr, byte*, int, Status> writeFn,
        IntPtr userDataHandle,
        Interop.Path* path
    )
    {
        var context = GetContext(userDataHandle);
        if (context != null)
        {
            var instance = context!.Instance;
            var ret = ResolvePath(path, ref instance);

            if (instance != null)
            {
                var value = instance switch
                {
                    string str => str,
                    object any => any.ToString() ?? string.Empty,
                    null => String.Empty,
                };

                if (value.Length > 0)
                {
                    unsafe
                    {
                        var buffer = Encoding.UTF8.GetBytes(value);
                        fixed (byte* ptr = &buffer[0])
                        {
                            var status = writeFn(writerHandle, ptr, value.Length);
                            if (status != Status.SUCCESS) return PathResolution.CHAIN_BROKEN;
                        }
                    }
                }
            }

            return ret;
        }

        return PathResolution.CHAIN_BROKEN;
    }

    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution ExpandLambda
    (
        IntPtr lambdaHandle, 
        IntPtr userDataHandle, 
        Interop.Path* path
    )
    {
        return PathResolution.NOT_FOUND_IN_CONTEXT;
    }

    #endregion Methods

    #region IDisposable

    public void Dispose()
    {
        if (handlers != null)
        {
            foreach (var handle in handlers)
            {
                var gcHandle = GCHandle.FromIntPtr(handle);
                gcHandle.Free();
            }

            handlers.Clear();
        }
    }

    #endregion IDisposable
}
