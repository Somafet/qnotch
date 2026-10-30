using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace QNotch.Core.Consumers;

internal static class ConsumerPipeIdentity
{
    public static void Verify(NamedPipeClientStream pipe)
    {
        using var identity = WindowsIdentity.GetCurrent();
        if (identity.User is not { } user || !HasOwner(pipe, user))
            throw new UnauthorizedAccessException("Consumer pipe is not owned by the current token user.");
    }

    // .NET's CurrentUserOnly client compares WindowsIdentity.Owner, which can be Administrators
    // for elevated tokens. Our server deliberately sets ownership to User, so check that exact SID.
    internal static bool HasOwner(NamedPipeClientStream pipe, SecurityIdentifier expected)
    {
        var status = GetSecurityInfo(pipe.SafePipeHandle, 6, 1, out var owner, out _, out _, out _, out var descriptor);
        try { return status == 0 && owner != 0 && new SecurityIdentifier(owner) == expected; }
        finally { if (descriptor != 0) LocalFree(descriptor); }
    }

    [DllImport("advapi32.dll")]
    static extern uint GetSecurityInfo(SafePipeHandle handle, int type, uint information, out nint owner, out nint group, out nint dacl, out nint sacl, out nint descriptor);
    [DllImport("kernel32.dll")] static extern nint LocalFree(nint memory);
}
