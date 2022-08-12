using System.Reflection;
using System.Linq.Expressions;
using System.Runtime.CompilerServices;

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
        #region Fields

        private static readonly Dictionary<nint, Dictionary<string, Func<object, object>>> types = new();

        #endregion Fields

        #region Methods

        public static object? Get(object instance, string name)
        {
            nint typeHandle = Type.GetTypeHandle(instance).Value;

            if (!types.TryGetValue(typeHandle, out Dictionary<string, Func<object, object>>? delegates))
            {
                lock (types)
                {
                    if (!types.TryGetValue(typeHandle, out delegates))
                    {
                        delegates = GetDelegates(instance.GetType());
                        types.Add(typeHandle, delegates);
                    }
                }
            }

            if (delegates.TryGetValue(name, out Func<object, object>? get))
            {
                return get(instance);
            }

            return null;
        }

        private static Dictionary<string, Func<object, object>> GetDelegates(Type type)
        {
            var fields = type.GetFields();
            var properties = type.GetProperties();

            var delegates = new Dictionary<string, Func<object, object>>(fields.Length + properties.Length);

            foreach (var field in fields)
            {
                var get = CreateAcessor(type, field);
                if (get == null) continue;

                delegates.Add(field.Name, get);
            }

            foreach (var property in properties)
            {
                var get = CreateAcessor(type, property);
                if (get == null) continue;

                delegates.Add(property.Name, get);
            }

            return delegates;
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