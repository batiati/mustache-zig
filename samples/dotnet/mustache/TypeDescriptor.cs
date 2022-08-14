using System.Reflection;
using System.Linq.Expressions;
using System.Runtime.CompilerServices;
using System.Text;

namespace mustache
{
    #region Documentation

    /// <summary>
    /// Cache for type metadata
    /// Converts FieldInfo and PropertyInfo to delegates to speed up the reflection
    /// </summary>

    #endregion Documentation

    internal static class TypeDescriptor
    {
        #region InnerTypes

        private delegate object? Getter(object instance);

        #region Documentation

        /// <summary>
        /// Represents a SOA (struct of arrays) containing an array of all names, sizes and delegates
        /// This approach sppeds up the match process, by reducing the walk into different regions of memory for each name
        /// </summary>

        #endregion Documentation

        private struct Descriptor
        {
            public byte[] names;

            public int[] sizes;
            
            public Getter[] getters;
        }

		#endregion InnerTypes

		#region Fields

		private static readonly Dictionary<nint, Descriptor> types = new();

        #endregion Fields

        #region Methods

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public static object? Get(object instance, ReadOnlySpan<byte> name)
        {
            var descriptor = GetDescriptor(instance);

            int lastPos = 0;
            for (int i = 0; i < descriptor.names.Length; i++)
            {
                var span = descriptor.names.AsSpan(lastPos, descriptor.sizes[i]);
                lastPos += descriptor.sizes[i];

                if (name.SequenceEqual(span))
                {
                    var get = descriptor.getters[i];
                    return get(instance);
                }
            }

            return null;
        }

        private static Descriptor GetDescriptor(object instance)
        {
            nint typeHandle = Type.GetTypeHandle(instance).Value;

            if (!types.TryGetValue(typeHandle, out Descriptor descriptor))
            {
                lock (types)
                {
                    if (!types.TryGetValue(typeHandle, out descriptor))
                    {
                        descriptor = CreateDescriptor(instance.GetType());
                        types.Add(typeHandle, descriptor);
                    }
                }
            }

            return descriptor;
        }

        private static Descriptor CreateDescriptor(Type type)
        {
            var fields = type.GetFields();
            var properties = type.GetProperties();

            var bufferSize = fields.Select(x => x.Name.Length).Sum() + properties.Select(x => x.Name.Length).Sum();
            var names = new List<byte>(bufferSize);
            
            var capacity = fields.Length + properties.Length;
            var sizes = new List<int>(capacity);
            var getters = new List<Getter>(capacity);

            foreach (var field in fields)
            {
                var get = CreateGetter(type, field);
                if (get == null) continue;

                var bytes = Encoding.UTF8.GetBytes(field.Name);
                names.AddRange(bytes);
                sizes.Add(bytes.Length);
                getters.Add(get);
            }

            foreach (var property in properties)
            {
                var get = CreateGetter(type, property);
                if (get == null) continue;

                var bytes = Encoding.UTF8.GetBytes(property.Name);
                names.AddRange(bytes);
                sizes.Add(bytes.Length);
                getters.Add(get);
            }

            return new Descriptor 
            {
                names = names.ToArray(),
                sizes = sizes.ToArray(),
                getters = getters.ToArray(),
            };
        }

        private static Getter? CreateGetter(Type type, MemberInfo memberInfo)
        {
            var instance = Expression.Parameter(typeof(object));
            var getParameters = new ParameterExpression[] { instance };
            
            // No need for type-checking here, we assure that this delegate is obtained after checking the instance's type
            var unsafeCast = Expression.Call(typeof(Unsafe), nameof(Unsafe.As), new[] { type }, instance);
        
            if (memberInfo is FieldInfo fieldInfo)
            {
                var getBody = Expression.Convert(Expression.Field(unsafeCast, fieldInfo), typeof(object));
                return Expression.Lambda<Getter>(getBody, getParameters).Compile();
            }
            else if (memberInfo is PropertyInfo propertyInfo)
            {
                var getMethod = propertyInfo.GetGetMethod(nonPublic: true);
                if (getMethod != null)
                {
                    var getBody = Expression.Convert(Expression.Call(unsafeCast, getMethod), typeof(object));
                    return Expression.Lambda<Getter>(getBody, getParameters).Compile();
                }
            }

            return null;
        }

        #endregion Methods
    }
}