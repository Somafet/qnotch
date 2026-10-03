using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;

namespace QNotch.Modules.Notifications;

/// <summary>Finds the window a "focus" action should bring forward and activates it.</summary>
internal static class WindowFinder
{
    const int GWL_EXSTYLE = -20, GW_OWNER = 4, SW_RESTORE = 9;
    const long WS_EX_TOOLWINDOW = 0x80;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    delegate bool EnumProc(nint hwnd, nint lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, nint lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(nint hwnd);
    [DllImport("user32.dll")] static extern bool IsWindow(nint hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(nint hwnd);
    [DllImport("user32.dll")] static extern nint GetWindow(nint hwnd, int cmd);
    [DllImport("user32.dll")] static extern int GetWindowTextLengthW(nint hwnd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint hwnd, int index);
    [DllImport("user32.dll")] static extern bool ShowWindow(nint hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("kernel32.dll")] static extern nint OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(nint handle);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(nint process, int infoClass, ref PROCESS_BASIC_INFORMATION info, int size, out int returned);

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION { public nint ExitStatus, PebBase, AffinityMask, BasePriority, Pid, ParentPid; }

    /// <summary>
    /// The topmost main window of <paramref name="pid"/> or of its nearest ancestor that has one. A hook or script usually runs in a
    /// windowless shell, so the walk ends at its terminal or editor. Returns 0 when nothing is found.
    /// </summary>
    public static nint Find(int pid)
    {
        var id = (uint)pid;
        for (var hop = 0; hop < 8 && id > 4; hop++)
        {
            var h = MainWindow(id);
            if (h != 0) return h;
            id = Parent(id);
        }
        return 0;
    }

    static nint MainWindow(uint pid)
    {
        nint found = 0;
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var owner);
            if (owner != pid || !IsWindowVisible(h) || GetWindow(h, GW_OWNER) != 0 || GetWindowTextLengthW(h) == 0) return true;
            if ((GetWindowLongPtr(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            found = h;
            return false;
        }, 0);
        return found;
    }

    static uint Parent(uint pid)
    {
        var p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (p == 0) return 0;
        try
        {
            var info = new PROCESS_BASIC_INFORMATION();
            return NtQueryInformationProcess(p, 0, ref info, Marshal.SizeOf<PROCESS_BASIC_INFORMATION>(), out _) == 0 ? (uint)info.ParentPid : 0;
        }
        finally { CloseHandle(p); }
    }

    /// <summary>Call from a click handler: Windows lets the process that received the last input set the foreground window.</summary>
    public static bool Focus(nint hwnd)
    {
        if (!IsWindow(hwnd)) return false;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        return SetForegroundWindow(hwnd);
    }
}

/// <summary>Resolves the <c>icon</c> field: a glyph name, an image file, or any other file (exe, shortcut) whose shell icon is used. Results are frozen and cached.</summary>
internal static class NotifyIcons
{
    public const string Bell = "", Dismiss = "";
    const int Size = 64, SIIGBF_ICONONLY = 0x4;
    const long MaxImageBytes = 4 << 20;

    public static readonly IReadOnlyDictionary<string, string> Glyphs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["bell"] = Bell, ["info"] = "", ["success"] = "", ["check"] = "", ["warning"] = "", ["error"] = "",
        ["chat"] = "", ["code"] = "", ["link"] = "", ["clock"] = "", ["download"] = "", ["bolt"] = "",
        ["person"] = "", ["folder"] = "", ["globe"] = "", ["mail"] = "", ["play"] = "", ["build"] = "",
    };

    static readonly string[] ImageExtensions = [".png", ".jpg", ".jpeg", ".bmp", ".gif", ".ico"];
    static readonly ConcurrentDictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static string LevelGlyph(NoteLevel level) => Glyphs[level switch { NoteLevel.Success => "success", NoteLevel.Warning => "warning", NoteLevel.Error => "error", _ => "bell" }];

    /// <summary>Any thread. Null for a glyph name, a missing file or anything unreadable. Only local drive paths: a UNC path would make Windows sign in to a remote server.</summary>
    public static async Task<ImageSource?> LoadAsync(string? spec)
    {
        if (string.IsNullOrWhiteSpace(spec) || Glyphs.ContainsKey(spec)) return null;
        if (Cache.TryGetValue(spec, out var hit)) return hit;
        ImageSource? img = null;
        try
        {
            if (spec.Length > 3 && spec[1] == ':' && Path.IsPathFullyQualified(spec) && File.Exists(spec))
                img = ImageExtensions.Contains(Path.GetExtension(spec), StringComparer.OrdinalIgnoreCase) ? LoadImage(spec) : await ShellIconAsync(spec);
        }
        catch (Exception ex) { Log.Warn($"Notification icon '{spec}' unreadable", ex); }
        if (Cache.Count > 64) Cache.Clear();
        Cache[spec] = img;
        return img;
    }

    static ImageSource? LoadImage(string path)
    {
        if (new FileInfo(path).Length > MaxImageBytes) return null;
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.UriSource = new Uri(path);
        bmp.DecodePixelWidth = Size;
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out nint hbitmap);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHCreateItemFromParsingName(string path, nint pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);

    /// <summary>IShellItemImageFactory needs an STA thread: a short-lived one per uncached icon.</summary>
    static Task<ImageSource?> ShellIconAsync(string path)
    {
        var tcs = new TaskCompletionSource<ImageSource?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var t = new Thread(() =>
        {
            nint hbm = 0;
            IShellItemImageFactory? f = null;
            try
            {
                var iid = typeof(IShellItemImageFactory).GUID;
                if (SHCreateItemFromParsingName(path, 0, ref iid, out f) != 0 || f.GetImage(new SIZE { cx = Size, cy = Size }, SIIGBF_ICONONLY, out hbm) != 0 || hbm == 0) { tcs.SetResult(null); return; }
                var src = Imaging.CreateBitmapSourceFromHBitmap(hbm, 0, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                src.Freeze();
                tcs.SetResult(src);
            }
            catch (Exception ex) { Log.Warn($"Icon for '{path}' failed", ex); tcs.TrySetResult(null); }
            finally
            {
                if (hbm != 0) DeleteObject(hbm);
                if (f is not null) Marshal.ReleaseComObject(f);
            }
        }) { IsBackground = true, Name = "QNotch.NotifyIcon" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        return tcs.Task;
    }
}

/// <summary>The HTTP bearer token in Windows Credential Manager (generic credential "QNotch/Notify"). Secrets never go in JSON.</summary>
internal static partial class NotifyToken
{
    const string Target = "QNotch/Notify";
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

    [LibraryImport("advapi32.dll")]
    private static partial void CredFree(nint buffer);

    /// <summary>The stored token; a new one is generated and stored when none exists or <paramref name="renew"/> is set.</summary>
    public static string Get(bool renew = false)
    {
        if (!renew && Read() is { Length: > 0 } t) return t;
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        if (!Write(token)) Log.Warn("Notification token could not be stored; it changes on every start");
        return token;
    }

    public static bool Matches(string expected, string given) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(given));

    static string? Read()
    {
        if (!CredRead(Target, Generic, 0, out var p)) return null;
        try
        {
            var c = Marshal.PtrToStructure<CREDENTIAL>(p);
            return c.CredentialBlobSize == 0 ? null : Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
        }
        finally { CredFree(p); }
    }

    static bool Write(string token)
    {
        nint blob = Marshal.StringToHGlobalUni(token), name = Marshal.StringToHGlobalUni(Target), user = Marshal.StringToHGlobalUni("QNotch");
        try
        {
            var c = new CREDENTIAL { Type = Generic, TargetName = name, CredentialBlob = blob, CredentialBlobSize = (uint)(token.Length * 2), Persist = PersistLocalMachine, UserName = user };
            return CredWrite(ref c, 0);
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(blob);
            Marshal.FreeHGlobal(name);
            Marshal.FreeHGlobal(user);
        }
    }
}
