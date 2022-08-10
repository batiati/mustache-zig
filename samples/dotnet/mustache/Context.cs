using System.Runtime.InteropServices;
using System.Reflection;
using System.Text;
using System.Collections;

namespace mustache
{
    internal sealed class Context
    {
        private static readonly int PATH_PART_SIZE = Marshal.SizeOf(typeof(Interop.PathPart));
        private object instance;

        public Context(object instance)
        {
            this.instance = instance;
        }

        public Interop.UserData GetUserData()
        {
            unsafe
            {
                return new Interop.UserData
                {
                    handle = IntPtr.Zero,
                    callbacks = new Interop.Callbacks
                    {
                        get = Get,
                        capacityHint = CapacityHint,
                        interpolate = Interpolate,
                        expandLambda = ExpandLambda,
                    }
                };
            }
        }

        private static object? GetValue(object instance, string key)
        {
            if (instance is IDictionary dictionary)
            {
                return dictionary.Contains(key) ? dictionary[key] : null;
            }

            Type type = instance.GetType();

            if (type.GetField(key) is FieldInfo fieldInfo)
            {
                return fieldInfo.GetValue(instance);
            }
            else if (type.GetProperty(key) is PropertyInfo propertyInfo)
            {
                return propertyInfo.GetValue(instance);
            }

            return null;
        }

        private unsafe static string[] GetPath(Interop.Path* path)
        {
            var array = new string[path->path_size];
            for (int i = 0; i < path->path_size; i++)
            {
                var pathPart = (Interop.PathPart*)(path->path + i);
                array[i] = Encoding.UTF8.GetString(pathPart->value, pathPart->size);
            }

            return array;
        }

        private unsafe Interop.PathResolution Get(IntPtr userDataHandle, Interop.Path* path, out Interop.UserData out_value)
        {
            _ = userDataHandle;

            var _path = GetPath(path);
            if (_path.Length == 1)
            {
                var next = GetValue(instance, _path[0]);
                if (next != null)
                {
                    var nextContext = new Context(next);
                    out_value = nextContext.GetUserData();
                    return Interop.PathResolution.FIELD;
                }
            }

            out_value = default(Interop.UserData);
            return Interop.PathResolution.NOT_FOUND_IN_CONTEXT;
        }

        private unsafe Interop.PathResolution CapacityHint(IntPtr userDataHandle, Interop.Path* path, out int out_value)
        {
            out_value = 100;
            return Interop.PathResolution.FIELD;
        }

        private unsafe Interop.PathResolutionOrError Interpolate(IntPtr writerHandle, IntPtr userDataHandle, Interop.Path* path)
        {
            _ = userDataHandle;

            var _path = GetPath(path);
            if (_path.Length == 1)
            {
                var next = GetValue(instance, _path[0]);
                if (next != null)
                {
                    unsafe
                    {
                        var buffer = Encoding.UTF8.GetBytes(next.ToString() ?? string.Empty);
                        fixed (byte* ptr = &buffer[0])
                        {
                            var ret = Interop.mustache_interpolate(writerHandle, ptr, buffer.Length);
                            if (ret != Interop.Status.SUCCESS) return new Interop.PathResolutionOrError { has_error = true, error_code = (int)ret };
                            return new Interop.PathResolutionOrError { result = Interop.PathResolution.FIELD };
                        }
                    }
                }
            }

            return new Interop.PathResolutionOrError { result = Interop.PathResolution.NOT_FOUND_IN_CONTEXT };
        }
        private unsafe Interop.PathResolutionOrError ExpandLambda(IntPtr lambdaHandle, IntPtr userDataHandle, Interop.Path* path)
        {
            return new Interop.PathResolutionOrError { result = Interop.PathResolution.NOT_FOUND_IN_CONTEXT };
        }
    }
}