using System.Runtime.InteropServices;
using System.Text;
using System.Collections;

namespace mustache
{
	#region Documentation

	/// <summary>
	/// Represents a context being evaluated
	/// </summary>

	#endregion Documentation

	internal sealed class Context : IDisposable
    {
		#region Fields

		private Context? parent;
		private List<GCHandle>? handlers;

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
			this.handlers = new List<GCHandle>();
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
			var list = handlers ?? parent?.handlers;
			var handle = GCHandle.Alloc(this);
			list!.Add(handle);

            return (IntPtr)handle;
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

        private static object? GetValue(object? instance, string key)
        {
            if (instance == null) return null;

            if (instance is IDictionary dictionary)
            {
                return dictionary.Contains(key) ? dictionary[key] : null;
            }
            else
            {
                return TypeDescriptor.Get(instance, key);
            }
        }

        private static unsafe string[] GetPath(Interop.Path* path)
        {
            var array = new string[path->path_size];
            for (int i = 0; i < path->path_size; i++)
            {
                var pathPart = (Interop.PathPart*)(path->path + i);
                array[i] = Encoding.UTF8.GetString(pathPart->value, pathPart->size);
            }

            return array;
        }

        private static unsafe Interop.PathResolution Get(IntPtr userDataHandle, Interop.Path* path, out Interop.UserData out_value)
        {
            var array = GetPath(path);
            if (array.Length == 1)
            {
                var context = GetContext(userDataHandle);
                if (context != null)
                {
                    var next = GetValue(context.Instance, array[0]);

                    if (next != null)
                    {
                        var nextContext = new Context(next, context);
                        out_value = nextContext.GetUserData();
                        return Interop.PathResolution.FIELD;
                    }
                }
            }

            out_value = default(Interop.UserData);
            return Interop.PathResolution.NOT_FOUND_IN_CONTEXT;
        }

        private static unsafe Interop.PathResolution CapacityHint(IntPtr userDataHandle, Interop.Path* path, out int out_value)
        {
            out_value = 100;
            return Interop.PathResolution.FIELD;
        }

        private static unsafe Interop.PathResolutionOrError Interpolate(IntPtr writerHandle, IntPtr userDataHandle, Interop.Path* path)
        {
            var array = GetPath(path);
            if (array.Length == 1)
            {
                var context = GetContext(userDataHandle);
                if (context != null)
                {
                    var buffer = GetValue(context.Instance, array[0]) switch
                    {
                        string str => Encoding.UTF8.GetBytes(str),
                        object any => Encoding.UTF8.GetBytes(any.ToString() ?? string.Empty),
						null => Array.Empty<byte>(),
                    };

					if (buffer.Length > 0)
                    {
						unsafe
                        {
                            fixed (byte* ptr = &buffer[0])
                            {
                                var ret = Interop.mustache_interpolate(writerHandle, ptr, buffer.Length);
                                if (ret != Interop.Status.SUCCESS) return new Interop.PathResolutionOrError { has_error = true, error_code = (int)ret };
                                return new Interop.PathResolutionOrError { result = Interop.PathResolution.FIELD };
                            }
                        }
                    }
                }
            }

            return new Interop.PathResolutionOrError { result = Interop.PathResolution.NOT_FOUND_IN_CONTEXT };
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
					handle.Free();
				}

				handlers.Clear();
			}
		}

		#endregion IDisposable
	}
}