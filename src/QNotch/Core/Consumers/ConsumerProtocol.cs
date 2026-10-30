using System.Text.Json;
using System.Text.Json.Serialization;

namespace QNotch.Core.Consumers;

// This file and the CLI client intentionally have no WPF dependencies.
public sealed record ConsumerRequest(int SchemaVersion, string Command, bool Details = false, string? Provider = null, string? Account = null);
public sealed record ConsumerSnapshot(string ModuleStatus, object? Data);
internal sealed record ConsumerEnvelope(int SchemaVersion, string AppVersion, string Platform, DateTime GeneratedAt, string ModuleStatus, object? Data);
internal sealed record ConsumerError(string Code, string Message);
internal sealed record ConsumerFailure(int SchemaVersion, ConsumerError Error);
internal sealed class ConsumerException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

internal static class ConsumerProtocol
{
    public const int Version = 1, DeadlineMs = 2000, MaxRequest = 4096, MaxResponse = 1024 * 1024, MaxClients = 4;
    public static string PipeName => "QNotch.Consumer" + (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") is { Length: > 0 } i ? "." + i : "");
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        MaxDepth = 32,
    };

    public static void Validate(ConsumerRequest request)
    {
        if (request.SchemaVersion != Version) throw new ConsumerException("unsupported_version", "Expected consumer schema version 1.");
        if (string.IsNullOrEmpty(request.Command) || request.Command.Length > 64 || request.Command.Any(c => c is not (>= 'a' and <= 'z' or '-')))
            throw new ConsumerException("invalid_arguments", "Invalid consumer command.");
        if (request.Provider is { Length: 0 } or { Length: > 128 }) throw new ConsumerException("invalid_arguments", "Invalid provider ID.");
        if (request.Account is { Length: 0 } or { Length: > 128 }) throw new ConsumerException("invalid_arguments", "Invalid account ID.");
    }

    public static byte[] Failure(string code, string message) => JsonSerializer.SerializeToUtf8Bytes(new ConsumerFailure(Version, new(code, message)), Json);

    public static async Task<byte[]> ReadLine(Stream stream, int limit, CancellationToken ct)
    {
        using var result = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var n = await stream.ReadAsync(buffer, ct);
            if (n == 0) throw new ConsumerException("connection_closed", "The consumer connection closed before answering.");
            var newline = Array.IndexOf(buffer, (byte)'\n', 0, n);
            var count = newline < 0 ? n : newline;
            if (result.Length + count > limit) throw new ConsumerException("size_limit", "Consumer message exceeds the size limit.");
            result.Write(buffer, 0, count);
            if (newline >= 0) return result.ToArray();
        }
    }

    public static async Task WriteLine(Stream stream, byte[] bytes, CancellationToken ct)
    {
        await stream.WriteAsync(bytes, ct);
        await stream.WriteAsync(new byte[] { (byte)'\n' }, ct);
        await stream.FlushAsync(ct);
    }

    public static string? Text(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        return new string(value.Where(c => !char.IsControl(c) && c is not ('\u202a' or '\u202b' or '\u202c' or '\u202d' or '\u202e' or '\u2066' or '\u2067' or '\u2068' or '\u2069')).Take(256).ToArray());
    }
}

/// <summary>UI-thread registry. Modules own projections; the host knows only registration and lifecycle.</summary>
public sealed class ConsumerRegistry
{
    readonly Dictionary<string, (string Module, string Status, Action<ConsumerRequest>? Validate)> _commands = new(StringComparer.Ordinal);
    readonly Dictionary<string, Func<ConsumerRequest, object>> _capture = new(StringComparer.Ordinal);

    public void Define(string command, string module, bool disabled, Action<ConsumerRequest>? validate = null) => _commands.Add(command, (module, disabled ? "disabled" : "initializing", validate));
    public void Register(string command, Func<ConsumerRequest, object> capture) => _capture.Add(command, capture);
    public void Complete(string module, bool ok)
    {
        foreach (var command in _commands.Where(c => c.Value.Module == module).Select(c => c.Key).ToArray())
            _commands[command] = (module, ok && _capture.ContainsKey(command) ? "ready" : "unavailable", _commands[command].Validate);
    }
    public ConsumerSnapshot Capture(ConsumerRequest request)
    {
        ConsumerProtocol.Validate(request);
        if (!_commands.TryGetValue(request.Command, out var entry)) throw new ConsumerException("invalid_arguments", "Unknown consumer command.");
        entry.Validate?.Invoke(request);
        return new(entry.Status, entry.Status == "ready" ? _capture[request.Command](request) : null);
    }
}
