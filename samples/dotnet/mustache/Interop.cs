using System.Runtime.InteropServices;

namespace mustache;

#region Documentation

/// <summary>
/// Native P/Invoke declarations
/// </summary>

#endregion Documentation

internal static class Interop
{
	#region InnerTypes

	public enum Status : int
    {
        SUCCESS = 0,
        INVALID_ARGUMENT = 1,
        PARSE_ERROR = 2,
        INTERPOLATION_ERROR = 3,
        OUT_OF_MEMORY = 4,
    }

    public enum PathResolution : int
    {
        NOT_FOUND_IN_CONTEXT = 0,
        CHAIN_BROKEN = 1,
        ITERATOR_CONSUMED = 2,
        LAMBDA = 3,
        FIELD = 4,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PathResolutionOrError
    {
        public PathResolution result;
        public bool has_error;
        public int error_code;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct PathPart
    {
        public byte* value;

        public int size;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct Path
    {
        public PathPart* path;

        public int path_size;

        public int index;

        public bool has_index;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct UserData
    {
        public IntPtr handle;

		[MarshalAs(UnmanagedType.FunctionPtr)]
		public GetDelegate? get;

		[MarshalAs(UnmanagedType.FunctionPtr)]
		public CapacityHintDelegate? capacityHint;

		[MarshalAs(UnmanagedType.FunctionPtr)]
		public InterpolateDelegate? interpolate;

		[MarshalAs(UnmanagedType.FunctionPtr)]
		public ExpandLambdaDelegate? expandLambda;
	}

	[UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
	public unsafe delegate PathResolution GetDelegate([In] IntPtr userDataHandle, [In] Path* path, [Out] out UserData out_value);

	[UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
	public unsafe delegate PathResolution CapacityHintDelegate([In] IntPtr userDataHandle, [In] Path* path, [Out] out int out_value);

	[UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
	public unsafe delegate PathResolutionOrError InterpolateDelegate([In] IntPtr writerHandle, [In] IntPtr userDataHandle, [In] Path* path);

	[UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
	public unsafe delegate PathResolutionOrError ExpandLambdaDelegate([In] IntPtr lambdaHandle, [In] IntPtr userDataHandle, [In] Path* path);

	#endregion InnerTypes

	#region Methods

	[DllImport("libmustache.so", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static unsafe extern Status mustache_create_template([In] byte* templateText, [In] int templateLen, [Out] out IntPtr templateHandle);

    [DllImport("libmustache.so", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern Status mustache_free_template([In] IntPtr templateHandle);

    [DllImport("libmustache.so", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static unsafe extern Status mustache_render([In] IntPtr templateHandle, [In] UserData userData, [Out] out byte* outBuffer, [Out] out int outBufferLen);

    [DllImport("libmustache.so", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static unsafe extern Status mustache_free_buffer([In] byte* buffer, [In] int bufferLen);

    [DllImport("libmustache.so", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static unsafe extern Status mustache_interpolate([In] IntPtr writerHandle, [In] byte* str, [In] int strLen);

	#endregion Methods
}
