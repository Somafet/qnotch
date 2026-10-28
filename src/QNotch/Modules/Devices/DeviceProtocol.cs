using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Encodings.Web;

namespace QNotch.Modules.Devices;

// Platform-free wire contract. Linked directly into the protocol regression executable.
public static class DeviceProtocol
{
    public const int Chunk = 65536;
    public const long MaxFile = 2L * 1024 * 1024 * 1024;
    public const int MaxSync = 8 * 1024 * 1024;
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Json);
    public static T Decode<T>(byte[] bytes) => JsonSerializer.Deserialize<T>(bytes, Json) ?? throw new IOException("Invalid message.");
    public static string Id() => Guid.NewGuid().ToString("D");
    public static bool ValidId(string value) => Guid.TryParseExact(value, "D", out var id) && id.ToString("D") == value;
    public static bool LocalAddress(string host) => IPAddress.TryParse(host, out var ip) && ip.AddressFamily == AddressFamily.InterNetwork && ip.ToString() == host &&
        (IPAddress.IsLoopback(ip) || ip.GetAddressBytes() is [10, _, _, _] or [192, 168, _, _] or [172, >= 16 and <= 31, _, _] or [169, 254, _, _] or [100, >= 64 and <= 127, _, _]);
    public static void ValidateName(string name)
    {
        if (string.IsNullOrEmpty(name)) throw new IOException("Unsupported file name.");
        var stem = name.Split('.')[0].ToUpperInvariant();
        if (name.Length == 0 || Encoding.UTF8.GetByteCount(name) > 180 || name is "." or ".." || name.EndsWith('.') || name.EndsWith(' ') ||
            name.Any(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c)) || stem is "CON" or "PRN" or "AUX" or "NUL" ||
            (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) && "123456789".Contains(stem[3])))
            throw new IOException("Unsupported file name.");
    }
    public static byte[] ConnectionKey(byte[] secret, byte[] challenge, byte[] hello) =>
        HMACSHA256.HashData(secret, (byte[])[.. challenge, .. SHA256.HashData(hello), .. Encoding.UTF8.GetBytes("qnotch-devices-v1")]);
    public static byte[] Aad(byte[] challenge, byte direction, ulong sequence)
    {
        byte[] aad = [.. challenge, direction, 0, 0, 0, 0, 0, 0, 0, 0];
        BinaryPrimitives.WriteUInt64BigEndian(aad.AsSpan(33), sequence);
        return aad;
    }
    public static byte[] Seal(byte[] key, byte[] plain, byte[] aad, byte[]? nonce = null)
    {
        if (plain.Length > Chunk) throw new IOException("Message too large.");
        var result = new byte[plain.Length + 28];
        (nonce ?? RandomNumberGenerator.GetBytes(12)).CopyTo(result, 0);
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(result.AsSpan(0, 12), plain, result.AsSpan(12, plain.Length), result.AsSpan(12 + plain.Length, 16), aad);
        return result;
    }
    public static byte[] Open(byte[] key, byte[] box, byte[] aad)
    {
        if (box.Length is < 28 or > Chunk + 28) throw new IOException("Invalid frame length.");
        var result = new byte[box.Length - 28];
        using var aes = new AesGcm(key, 16);
        aes.Decrypt(box.AsSpan(0, 12), box.AsSpan(12, result.Length), box.AsSpan(12 + result.Length, 16), result, aad);
        return result;
    }
    public static async Task WritePacket(Stream stream, byte[] bytes, CancellationToken ct)
    {
        var size = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(size, (uint)bytes.Length);
        await stream.WriteAsync(size, ct); await stream.WriteAsync(bytes, ct);
    }
    public static async Task<byte[]> ReadPacket(Stream stream, int max, CancellationToken ct)
    {
        var size = new byte[4]; await stream.ReadExactlyAsync(size, ct);
        var n = BinaryPrimitives.ReadUInt32BigEndian(size);
        if (n == 0 || n > max) throw new IOException("Invalid packet length.");
        var bytes = new byte[n]; await stream.ReadExactlyAsync(bytes, ct); return bytes;
    }
}

public sealed record DeviceHello(int V, string Id, bool Pair, string Nonce);
public sealed record DevicePeer(string Id, string Name, string Host, int Port, bool Receive = true, bool SyncNotes = false, bool SyncClipboard = false);
public sealed record DeviceInvitation(int V, string Id, string Name, string Host, int Port, string Secret, long Expires)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public string Code => "qnotch-device:" + Convert.ToBase64String(DeviceProtocol.Encode(this));
    public static DeviceInvitation Parse(string code)
    {
        if (code.Length > 4096 || !code.StartsWith("qnotch-device:", StringComparison.Ordinal)) throw new IOException("Invalid invitation.");
        var item = DeviceProtocol.Decode<DeviceInvitation>(Convert.FromBase64String(code[14..]));
        if (item.V != 1 || !DeviceProtocol.ValidId(item.Id) || item.Name is not { Length: > 0 and <= 80 } || !DeviceProtocol.LocalAddress(item.Host) ||
            item.Port is < 1 or > 65535 || Convert.FromBase64String(item.Secret).Length != 32 || item.Expires <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
            throw new IOException("Invalid or expired invitation.");
        return item;
    }
}
public sealed record DeviceMessage(string Op, string Id = "", string Name = "", int Port = 0, string Key = "", string Text = "", long Size = 0);
public sealed record DeviceReply(bool Ok, string Error = "", string Id = "", string Name = "", long Size = 0);

public sealed class DeviceChannel(Stream stream, byte[] key, byte[] challenge, bool client, CancellationToken ct)
{
    ulong sent, received;
    public Task Send(byte[] plain) => DeviceProtocol.WritePacket(stream,
        DeviceProtocol.Seal(key, plain, DeviceProtocol.Aad(challenge, (byte)(client ? 0 : 1), sent++)), ct);
    public async Task<byte[]> Read() => DeviceProtocol.Open(key, await DeviceProtocol.ReadPacket(stream, DeviceProtocol.Chunk + 28, ct),
        DeviceProtocol.Aad(challenge, (byte)(client ? 1 : 0), received++));
    public Task Reply(DeviceReply reply) => Send(DeviceProtocol.Encode(reply));
    public async Task SendBytes(byte[] data)
    {
        for (var offset = 0; offset < data.Length; offset += DeviceProtocol.Chunk)
            await Send(data[offset..Math.Min(data.Length, offset + DeviceProtocol.Chunk)]);
    }
    public async Task<byte[]> ReadBytes(long count)
    {
        if (count is < 1 or > DeviceProtocol.MaxSync) throw new IOException("Invalid synchronization size.");
        var result = new byte[count]; var offset = 0;
        while (offset < result.Length)
        {
            var chunk = await Read();
            if (chunk.Length == 0 || chunk.Length > result.Length - offset) throw new IOException("Invalid synchronization chunk.");
            chunk.CopyTo(result, offset); offset += chunk.Length;
        }
        return result;
    }
    public async Task CheckReply()
    {
        var reply = DeviceProtocol.Decode<DeviceReply>(await Read());
        if (!reply.Ok) throw new IOException(reply.Error.Length > 0 ? reply.Error : "Device declined the request.");
    }
}
