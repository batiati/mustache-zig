using System.Runtime.CompilerServices;
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

    [SkipLocalsInit]
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct PathPart
    {
        public byte* value;

        public int size;

        public PathPart* next;
    }

    [SkipLocalsInit]
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct Path
    {
        public PathPart* root;

        public int index;

        public byte has_index;
    }

    [SkipLocalsInit]
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct UserData
    {
        public void* handle;

        public delegate* unmanaged[Cdecl]<void*, Path*, UserData*, PathResolution> get;

        public delegate* unmanaged[Cdecl]<void*, Path*, int*, PathResolution> capacityHint;

        public delegate* unmanaged[Cdecl]<void*, delegate* unmanaged[Cdecl, SuppressGCTransition]<void*, byte*, int, Status>, void*, Path*, PathResolution> interpolate;

        public delegate* unmanaged[Cdecl]<void*, void*, Path*, PathResolution> expandLambda;
    }

    #endregion InnerTypes

    private const string DllName = "mustache";

    #region Methods

    [SkipLocalsInit]
    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_create_template(byte* templateText, int templateLen, out void* templateHandle);

    [SkipLocalsInit]
    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_free_template(void* templateHandle);

    [SkipLocalsInit]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_render(void* templateHandle, UserData userData, out byte* outBuffer, out int outBufferLen);

    [SkipLocalsInit]
    [SuppressGCTransition]
    [DllImport(DllName, CallingConvention = CallingConvention.Cdecl)]
    public static unsafe extern Status mustache_free_buffer(void* buffer, int bufferLen);

    #endregion Methods
}
