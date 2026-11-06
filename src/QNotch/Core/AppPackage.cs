using System.Runtime.InteropServices;

namespace QNotch.Core;

/// <summary>
/// The Microsoft Store build is the same QNotch.exe inside an MSIX package (src/QNotch/Packaging). When it runs with package identity,
/// the Store installs updates, Windows owns the install folder and start at sign-in is the package's startup task.
/// </summary>
public static class AppPackage
{
    /// <summary>The Store product id from Partner Center.</summary>
    public const string StoreProductId = "9MTFK5R4799F";

    /// <summary>Must match the windows.startupTask TaskId in Packaging/AppxManifest.xml.</summary>
    public const string StartupTaskId = "QNotchStartup";

    public static readonly bool IsPackaged = Detect();

    /// <summary>
    /// The path other programs use to run QNotch (agent hooks). Inside the package that is the qnotch.exe execution alias: the install
    /// folder under WindowsApps changes with every Store update and other processes cannot reliably start an exe there.
    /// </summary>
    public static string CommandPath => IsPackaged
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "qnotch.exe")
        : Environment.ProcessPath!;

    public static string StoreLink => "ms-windows-store://pdp/?productid=" + StoreProductId;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetCurrentPackageFullName(ref int length, char[]? name);

    static bool Detect()
    {
        try
        {
            var length = 0;
            // ERROR_INSUFFICIENT_BUFFER (122): there is a package name to return. APPMODEL_ERROR_NO_PACKAGE (15700): unpackaged.
            return GetCurrentPackageFullName(ref length, null) == 122;
        }
        catch (Exception ex) when (ex is EntryPointNotFoundException or DllNotFoundException) { return false; }
    }
}
