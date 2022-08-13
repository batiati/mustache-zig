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

        private struct Descriptor
        {
            public byte[] name;
            public Func<object, object> get;
        }

		#endregion InnerTypes

		#region Fields

		private static readonly Dictionary<nint, Descriptor[]> types = new();

        #endregion Fields

        #region Methods

        public static object? Get(object instance, ReadOnlySpan<byte> name)
        {
            nint typeHandle = Type.GetTypeHandle(instance).Value;

            if (!types.TryGetValue(typeHandle, out Descriptor[]? descriptors))
            {
                lock (types)
                {
                    if (!types.TryGetValue(typeHandle, out descriptors))
                    {
						descriptors = GetDelegates(instance.GetType());
                        types.Add(typeHandle, descriptors);
                    }
                }
            }

            foreach (var descriptor in descriptors)
            {
                if (name.SequenceEqual(descriptor.name))
                {
                    return descriptor.get;
                }
            }

            return null;
        }

        private static Descriptor[] GetDelegates(Type type)
        {
            var fields = type.GetFields();
            var properties = type.GetProperties();

            var descriptors = new List<Descriptor>(fields.Length + properties.Length);

            foreach (var field in fields)
            {
                var get = CreateAcessor(type, field);
                if (get == null) continue;

                descriptors.Add(new Descriptor { name = Encoding.UTF8.GetBytes(field.Name), get = get });
            }

            foreach (var property in properties)
            {
                var get = CreateAcessor(type, property);
                if (get == null) continue;

                descriptors.Add(new Descriptor { name = Encoding.UTF8.GetBytes(property.Name), get = get });
            }

            return descriptors.ToArray();
        }

        private static Func<object, object>? CreateAcessor(Type type, MemberInfo memberInfo)
        {
            var instance = Expression.Parameter(typeof(object));

            if (memberInfo is FieldInfo fieldInfo)
            {
                var getBody = Expression.Convert(Expression.Field(Expression.Convert(instance, type), fieldInfo), typeof(object));
                var getParameters = new ParameterExpression[] { instance };

                return Expression.Lambda<Func<object, object>>(getBody, getParameters).Compile();
            }
            else if (memberInfo is PropertyInfo propertyInfo)
            {
                var getMethod = propertyInfo.GetGetMethod(nonPublic: true);
                if (getMethod != null)
                {
                    var getBody = Expression.Convert(Expression.Call(Expression.Convert(instance, type), getMethod), typeof(object));
                    var getParameters = new ParameterExpression[] { instance };
                    return Expression.Lambda<Func<object, object>>(getBody, getParameters).Compile();
                }
            }

            return null;
        }

        #endregion Methods
    }
}