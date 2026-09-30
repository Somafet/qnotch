using System.Runtime.InteropServices;

namespace QNotch.Modules.Clipboard;

internal enum ReadResult { Ok, Busy, Skip }

/// <summary>Raw clipboard access. Reads are short and never sleep: a busy clipboard is reported so the caller retries later.</summary>
internal static unsafe partial class ClipboardNative
{
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    const uint CF_UNICODETEXT = 13, CF_DIB = 8, GMEM_MOVEABLE = 2;
    public const int MaxChars = 200_000;
    const long MaxDibBytes = 34 << 20; // a 4K 32 bpp frame

    static readonly uint FmtExclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
    static readonly uint FmtViewerIgnore = RegisterClipboardFormat("Clipboard Viewer Ignore");
    static readonly uint FmtHistory = RegisterClipboardFormat("CanIncludeInClipboardHistory");

    [LibraryImport("user32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static partial bool AddClipboardFormatListener(nint hwnd);
    [LibraryImport("user32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] public static partial bool RemoveClipboardFormatListener(nint hwnd);
    [LibraryImport("user32.dll", SetLastError = true)][return: MarshalAs(UnmanagedType.Bool)] private static partial bool OpenClipboard(nint hwnd);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool CloseClipboard();
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool EmptyClipboard();
    [LibraryImport("user32.dll")] private static partial nint GetClipboardData(uint format);
    [LibraryImport("user32.dll")] private static partial nint SetClipboardData(uint format, nint mem);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool IsClipboardFormatAvailable(uint format);
    [LibraryImport("user32.dll")] public static partial uint GetClipboardSequenceNumber();
    [LibraryImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", StringMarshalling = StringMarshalling.Utf16)] private static partial uint RegisterClipboardFormat(string name);
    [LibraryImport("kernel32.dll")] private static partial nint GlobalAlloc(uint flags, nuint bytes);
    [LibraryImport("kernel32.dll")] private static partial nint GlobalFree(nint mem);
    [LibraryImport("kernel32.dll")] private static partial nint GlobalLock(nint mem);
    [LibraryImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool GlobalUnlock(nint mem);
    [LibraryImport("kernel32.dll")] private static partial nuint GlobalSize(nint mem);

    /// <summary>Reads text (preferred) or a DIB. Blocks while a delayed-rendering owner produces the data: call it from the clipboard worker thread only. Skip: nothing usable, flagged sensitive, or too large. Busy: clipboard held by another process.</summary>
    public static ReadResult Read(nint hwnd, out string? text, out byte[]? dib)
    {
        text = null; dib = null;
        if (IsClipboardFormatAvailable(FmtExclude) || IsClipboardFormatAvailable(FmtViewerIgnore)) return ReadResult.Skip;
        bool hasText = IsClipboardFormatAvailable(CF_UNICODETEXT);
        if (!hasText && !IsClipboardFormatAvailable(CF_DIB)) return ReadResult.Skip;
        if (!OpenClipboard(hwnd)) return ReadResult.Busy;
        try
        {
            if (HistoryDenied()) return ReadResult.Skip;
            if (hasText) text = ReadText(); else dib = ReadDib();
            return text is null && dib is null ? ReadResult.Skip : ReadResult.Ok;
        }
        finally { CloseClipboard(); }
    }

    static bool HistoryDenied()
    {
        if (!IsClipboardFormatAvailable(FmtHistory)) return false;
        var h = GetClipboardData(FmtHistory);
        if (h == 0 || GlobalSize(h) < 4) return false;
        var p = GlobalLock(h);
        if (p == 0) return false;
        try { return *(int*)p == 0; } finally { GlobalUnlock(h); }
    }

    static string? ReadText()
    {
        var h = GetClipboardData(CF_UNICODETEXT);
        if (h == 0) return null;
        int max = (int)Math.Min(GlobalSize(h) / 2, MaxChars + 1);
        var p = GlobalLock(h);
        if (p == 0) return null;
        try
        {
            var span = new ReadOnlySpan<char>((void*)p, max);
            int len = span.IndexOf('\0');
            if (len < 0) len = max;
            return len > MaxChars ? null : new string(span[..len]);
        }
        finally { GlobalUnlock(h); }
    }

    static byte[]? ReadDib()
    {
        var h = GetClipboardData(CF_DIB);
        if (h == 0) return null;
        long size = (long)GlobalSize(h);
        if (size < 40 || size > MaxDibBytes) return null;
        var p = GlobalLock(h);
        if (p == 0) return null;
        try { return new ReadOnlySpan<byte>((void*)p, (int)size).ToArray(); } finally { GlobalUnlock(h); }
    }

    public static bool WriteText(nint hwnd, string text) =>
        Write(hwnd, CF_UNICODETEXT, (text.Length + 1) * 2, p =>
        {
            text.AsSpan().CopyTo(new Span<char>((void*)p, text.Length));
            ((char*)p)[text.Length] = '\0';
        });

    public static bool WriteDib(nint hwnd, byte[] dib) =>
        Write(hwnd, CF_DIB, dib.Length, p => dib.CopyTo(new Span<byte>((void*)p, dib.Length)));

    static bool Write(nint hwnd, uint format, int bytes, Action<nint> fill)
    {
        bool opened = false;
        for (int i = 0; i < 5 && !(opened = OpenClipboard(hwnd)); i++) Thread.Sleep(10);
        if (!opened) return false;
        try
        {
            EmptyClipboard();
            var mem = GlobalAlloc(GMEM_MOVEABLE, (nuint)bytes);
            if (mem == 0) return false;
            var p = GlobalLock(mem);
            if (p == 0) { GlobalFree(mem); return false; }
            fill(p);
            GlobalUnlock(mem);
            if (SetClipboardData(format, mem) != 0) return true; // the system owns the memory now
            GlobalFree(mem);
            return false;
        }
        finally { CloseClipboard(); }
    }
}
