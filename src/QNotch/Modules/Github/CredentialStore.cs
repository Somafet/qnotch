using System.Runtime.InteropServices;

namespace QNotch.Modules.Github;

/// <summary>The GitHub token in Windows Credential Manager (generic credential "QNotch/GitHub"). Raw advapi32, no WinRT needed.</summary>
internal static partial class CredentialStore
{
    const string Target = "QNotch/GitHub";
    const uint Generic = 1, PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential)]
    struct CREDENTIAL
    {
        public uint Flags, Type;
        public nint TargetName, Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public nint CredentialBlob;
        public uint Persist, AttributeCount;
        public nint Attributes, TargetAlias, UserName;
    }

    [LibraryImport("advapi32.dll", EntryPoint = "CredReadW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredRead(string target, uint type, uint flags, out nint credential);

    [LibraryImport("advapi32.dll", EntryPoint = "CredWriteW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredWrite(ref CREDENTIAL credential, uint flags);

    [LibraryImport("advapi32.dll", EntryPoint = "CredDeleteW", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CredDelete(string target, uint type, uint flags);

    [LibraryImport("advapi32.dll")]
    private static partial void CredFree(nint buffer);

    public static string? Read()
    {
        if (!CredRead(Target, Generic, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            return c.CredentialBlobSize == 0 ? null : Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
        }
        finally { CredFree(p); }
    }

    public static bool Write(string token)
    {
        var blob = Marshal.StringToHGlobalUni(token);
        var name = Marshal.StringToHGlobalUni(Target);
        var user = Marshal.StringToHGlobalUni("QNotch");
        try
        {
            var c = new CREDENTIAL
            {
                Type = Generic, TargetName = name, CredentialBlob = blob, CredentialBlobSize = (uint)(token.Length * 2),
                Persist = PersistLocalMachine, UserName = user,
            };
            return CredWrite(ref c, 0);
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(blob);
            Marshal.FreeHGlobal(name);
            Marshal.FreeHGlobal(user);
        }
    }

    public static void Delete() => CredDelete(Target, Generic, 0);
}
