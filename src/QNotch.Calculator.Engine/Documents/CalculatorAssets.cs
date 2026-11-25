using System.Reflection;

namespace Calc.Documents;

/// <summary>Files Calc shipped beside its executable. QNotch is a single file, so they travel as resources and are written under the
/// calculator data folder the first time something needs a real path (a browser opening help or a share link).</summary>
public static class CalculatorAssets
{
    static readonly string[] ViewerFiles = ["index.html", "viewer.css", "viewer.js", "codec.js"];

    static Assembly Owner => typeof(CalculatorAssets).Assembly;

    static byte[] Bytes(string resource)
    {
        using var stream = Owner.GetManifestResourceStream(resource) ?? throw new FileNotFoundException("Missing resource " + resource);
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    }

    /// <summary>Writes a file only when its content differs, through a temp file, so an open browser tab never reads a half-written one.</summary>
    static void WriteIfChanged(string path, byte[] content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path) && new FileInfo(path).Length == content.Length && File.ReadAllBytes(path).AsSpan().SequenceEqual(content)) return;
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, content);
        File.Move(temp, path, true);
    }

    /// <summary>The static share viewer folder's index.html, written out on demand.</summary>
    public static string WriteShareViewer(string dataDirectory)
    {
        var folder = Path.Combine(dataDirectory, "ShareViewer");
        foreach (var file in ViewerFiles) WriteIfChanged(Path.Combine(folder, file), Bytes("Calc.ShareViewer." + file));
        return Path.Combine(folder, "index.html");
    }

    public static string WriteHelp(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, "Help.html");
        WriteIfChanged(path, Bytes("Calc.Help"));
        return path;
    }

    public static string WriteNotices(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, "THIRD-PARTY-NOTICES.txt");
        WriteIfChanged(path, Bytes("Calc.Notices"));
        return path;
    }
}
