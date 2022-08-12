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
        public nint handle;

        public delegate* unmanaged[Cdecl]<nint, Path*, UserData*, PathResolution> get;

        public delegate* unmanaged[Cdecl]<nint, Path*, int*, PathResolution> capacityHint;

        public delegate* unmanaged[Cdecl]<nint, delegate* unmanaged[Cdecl, SuppressGCTransition]<nint, byte*, int, Status>, nint, Path*, PathResolution> interpolate;

        public delegate* unmanaged[Cdecl]<nint, nint, Path*, PathResolution> expandLambda;
    }

    #endregion InnerTypes

    private const string DllName = "mustache";

    #region Methods

    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_create_template(byte* templateText, int templateLen, out nint templateHandle);

    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static extern Status mustache_free_template(nint templateHandle);

    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_render(nint templateHandle, UserData userData, out nint outBuffer, out int outBufferLen);

    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_free_buffer(nint buffer, int bufferLen);

    #endregion Methods
}
