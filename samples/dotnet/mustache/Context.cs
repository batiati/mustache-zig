using System.Runtime.InteropServices;
using System.Collections;

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

    private static readonly Interop.GetDelegate GetCallback;
    private static readonly Interop.CapacityHintDelegate CapacityHintCallback;
    private static readonly Interop.InterpolateDelegate InterpolateCallback;
    private static readonly Interop.ExpandLambdaDelegate ExpandLambdaCallback;

    #endregion Fields

    #region Properties

    public object Instance { get; private set; }

    #endregion Properties

    #region Constructor

    static Context()
    {
        unsafe
        {
            GetCallback = new Interop.GetDelegate(Get);
            CapacityHintCallback = new Interop.CapacityHintDelegate(CapacityHint);
            InterpolateCallback = new Interop.InterpolateDelegate(Interpolate);
            ExpandLambdaCallback = new Interop.ExpandLambdaDelegate(ExpandLambda);
        }
    }

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

    public Interop.UserData GetUserData()
    {
        unsafe
        {
            return new Interop.UserData
            {
                handle = GetHandle(),
                get = GetCallback,
                capacityHint = CapacityHintCallback,
                interpolate = InterpolateCallback,
                expandLambda = ExpandLambdaCallback,
            };
        }
    }

    private static Context? GetContext(IntPtr handle)
    {
        return GCHandle.FromIntPtr(handle).Target as Context;
    }

    private unsafe static Interop.PathResolution ResolvePath(Interop.Path* path, ref object? instance)
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



    private static unsafe Interop.PathResolution Get(IntPtr userDataHandle, Interop.Path* path, out Interop.UserData out_value)
    {
        out_value = default(Interop.UserData);

        var context = GetContext(userDataHandle);
        if (context == null) return Interop.PathResolution.CHAIN_BROKEN;

        var instance = context.Instance;
        var ret = ResolvePath(path, ref instance);

        if (instance != null)
        {
            var nextContext = new Context(instance, context);
            out_value = nextContext.GetUserData();
        }

        return ret;
    }

    private static unsafe Interop.PathResolution CapacityHint(IntPtr userDataHandle, Interop.Path* path, out int out_value)
    {
        out_value = 0;

        var context = GetContext(userDataHandle);
        if (context == null) return Interop.PathResolution.CHAIN_BROKEN;

        var instance = context.Instance;
        var ret = ResolvePath(path, ref instance);

        if (instance != null)
        {
            const int NUMBER_HINT = 16;

            out_value = instance switch
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

    private static unsafe Interop.PathResolutionOrError Interpolate(IntPtr writerHandle, IntPtr userDataHandle, Interop.Path* path)
    {
        var context = GetContext(userDataHandle);
        if (context == null) new Interop.PathResolutionOrError { result = Interop.PathResolution.CHAIN_BROKEN };

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
                    fixed (char* ptr = value)
                    {
                        var status = Interop.mustache_interpolateW(writerHandle, ptr, value.Length);
                        if (status != Interop.Status.SUCCESS) return new Interop.PathResolutionOrError { has_error = true, error_code = (int)ret };
                    }
                }
            }
        }

        return new Interop.PathResolutionOrError { result = ret };
    }

    private static unsafe Interop.PathResolutionOrError ExpandLambda(IntPtr lambdaHandle, IntPtr userDataHandle, Interop.Path* path)
    {
        return new Interop.PathResolutionOrError { result = Interop.PathResolution.NOT_FOUND_IN_CONTEXT };
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
