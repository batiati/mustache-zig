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

    private readonly bool isRootContext;
    private readonly List<nint> handlers;

    #endregion Fields

    #region Properties

    public object Instance { get; }

    #endregion Properties

    #region Constructor

    public Context(object instance)
    {
        this.Instance = instance;
        this.isRootContext = true;
        this.handlers = new List<nint>();
    }

    private Context(object instance, Context parent)
    {
        this.Instance = instance;
        this.isRootContext = false;
        this.handlers = parent.handlers;
    }

    #endregion Constructor

    #region Methods

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private unsafe void* GetHandle()
    {
        var gcHandle = GCHandle.Alloc(this, GCHandleType.Normal);
        var handle = GCHandle.ToIntPtr(gcHandle);
        handlers.Add(handle);

        return (void*)handle;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public UserData GetUserData()
    {
        unsafe
        {
            return new UserData
            {
                handle = GetHandle(),
                get = &Get,
                interpolate = &Interpolate,
                expandLambda = &ExpandLambda,
            };
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static unsafe Context? GetContext(void* handle)
    {
        var gcHandle = GCHandle.FromIntPtr(new IntPtr(handle));
        return gcHandle.Target as Context;
    }

    [SkipLocalsInit]
    private unsafe static (PathResolution, object?) ResolvePath(Interop.Path* path, object context)
    {
        object? instance = context;

        var iterator = new PathIterator(path);
        while (iterator.MoveNext())
        {
            if (instance is IDictionary dictionary)
            {
                var key = Encoding.UTF8.GetString(iterator.partName);
                instance = dictionary.Contains(key) ? dictionary[key] : null;
            }
            else if (instance != null)
            {
                instance = TypeDescriptor.Get(instance, iterator.partName);
            }

            if (instance == null) break;
        }

        if (iterator.Index is int index)
        {
            if (instance is bool value)
            {
                if (value == false || index > 0)
                {
                    return (PathResolution.ITERATOR_CONSUMED, null);
                }
            }
            else if (instance is IList list)
            {
                if (index >= list.Count)
                {
                    return (PathResolution.ITERATOR_CONSUMED, null);
                }
                else
                {
                    instance = list[index];
                }
            }
            else if (instance == null)
            {
                return (PathResolution.ITERATOR_CONSUMED, null);
            }
            else if (index > 0)
            {
                return (PathResolution.ITERATOR_CONSUMED, null);
            }
        }

        if (instance == null)
        {
            if (iterator.IsRoot)
            {
                return (PathResolution.NOT_FOUND_IN_CONTEXT, null);
            }
            else
            {
                return (PathResolution.CHAIN_BROKEN, null);
            }
        }
        else
        {
            return (PathResolution.FIELD, instance);
        }
    }

    [SkipLocalsInit]
    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution Get
    (
        void* userDataHandle,
        Interop.Path* path,
        UserData* out_value
    )
    {
        var context = GetContext(userDataHandle);
        if (context == null) return PathResolution.CHAIN_BROKEN;

        var (ret, instance) = ResolvePath(path, context.Instance);

        if (instance != null)
        {
            var nextContext = new Context(instance, context);
            *out_value = nextContext.GetUserData();
        }

        return ret;
    }

    [SkipLocalsInit]
    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution Interpolate
    (
        void* writerHandle,
        delegate* unmanaged[Cdecl, SuppressGCTransition]<void*, byte*, int, Status> writeFn,
        void* userDataHandle,
        Interop.Path* path
    )
    {
        var context = GetContext(userDataHandle);
        if (context != null)
        {
            var (ret, instance) = ResolvePath(path, context!.Instance);

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
                    var encoder = Encoding.UTF8.GetEncoder();

                    unsafe
                    {
                        // Converts from UTF-16 directly on the writerFn
                        const int BUFFER_LEN = 128;
                        byte* buffer = stackalloc byte[BUFFER_LEN];

                        int charsOffSet = 0;
                        int charsCount = value.Length;

                        fixed (char* input = value)
                        {
                            for (; ; )
                            {
                                encoder.Convert(input + charsOffSet, charsCount, buffer, BUFFER_LEN, true, out int charsUsed, out int bytesUsed, out bool completed);

                                var status = writeFn(writerHandle, buffer, bytesUsed);
                                if (status != Status.SUCCESS) return PathResolution.CHAIN_BROKEN;

                                if (completed) break;
                                charsCount -= charsUsed;
                                charsOffSet += charsUsed;
                            }
                        }
                    }
                }
            }

            return ret;
        }

        return PathResolution.CHAIN_BROKEN;
    }

    [SkipLocalsInit]
    [UnmanagedCallersOnly(CallConvs = new Type[] { typeof(CallConvCdecl) })]
    private static unsafe PathResolution ExpandLambda
    (
        void* lambdaHandle,
        void* userDataHandle,
        Interop.Path* path
    )
    {
        return PathResolution.NOT_FOUND_IN_CONTEXT;
    }

    #endregion Methods

    #region IDisposable

    public void Dispose()
    {
        if (isRootContext)
        {
            foreach (var handle in handlers)
            {
                var gcHandle = GCHandle.FromIntPtr(new IntPtr(handle));
                gcHandle.Free();
            }

            handlers.Clear();
        }
    }

    #endregion IDisposable
}
