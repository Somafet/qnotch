using System.Text.Json;

namespace Calc.Documents;

internal static class AtomicJson
{
    internal static T Read<T>(string path, long maxBytes, Action<T> validate)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > maxBytes) throw new InvalidDataException("Document too large");
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        if (stream.ReadByte() != -1) throw new InvalidDataException("Document changed while reading");
        var value = JsonSerializer.Deserialize<T>(bytes) ?? throw new InvalidDataException("Empty document");
        validate(value);
        return value;
    }

    internal static (T Value, bool Recovered) Load<T>(string path, long maxBytes, Action<T> validate)
    {
        try { return (Read(path, maxBytes, validate), false); }
        catch (Exception e) when (e is not UnsupportedDocumentVersionException && e is IOException or JsonException or InvalidDataException)
        {
            var backup = Read(path + ".bak", maxBytes, validate);
            if (File.Exists(path)) File.Move(path, path + $".corrupt-{Guid.NewGuid():N}");
            File.Copy(path + ".bak", path);
            return (backup, true);
        }
    }

    internal static void Write<T>(string path, T value)
    {
        var temporary = path + $".{Guid.NewGuid():N}.tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value); stream.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temporary, path, path + ".bak");
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
