using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace QNotch.Core.Consumers;

internal static class ConsumerCli
{
    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);

    internal static ConsumerRequest Parse(string command, string[] args)
    {
        bool details = false;
        string? provider = null, account = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < args.Length; i++)
        {
            var flag = args[i];
            if (!seen.Add(flag)) throw new ConsumerException("invalid_arguments", "Duplicate option.");
            switch (flag)
            {
                case "--json": break;
                case "--details": details = true; break;
                case "--provider": case "--account":
                    if (++i == args.Length || args[i].StartsWith('-')) throw new ConsumerException("invalid_arguments", "A filter needs a value.");
                    if (flag == "--provider") provider = args[i]; else account = args[i];
                    break;
                default: throw new ConsumerException("invalid_arguments", "Unknown option. Use --help.");
            }
        }
        var request = new ConsumerRequest(ConsumerProtocol.Version, command, details, provider, account);
        ConsumerProtocol.Validate(request);
        return request;
    }

    public static int Run(string command, string[] args, string help, Action<ConsumerRequest> validate)
    {
        AttachConsole(-1);
        if (args.Length == 1 && args[0] is "--help" or "-h")
        {
            Console.Out.WriteLine(help +
                "\nRead cached data from the running app. JSON output; no refresh. Exit codes: 0 snapshot, 3 no service, 4 bad arguments, 1 failure.");
            return 0;
        }
        try
        {
            var request = Parse(command, args);
            validate(request);
            var bytes = Exchange(request).GetAwaiter().GetResult();
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            if (!root.TryGetProperty("schema_version", out var version) || !version.TryGetInt32(out var v) || v != ConsumerProtocol.Version)
                throw new ConsumerException("unsupported_version", "Incompatible consumer response.");
            if (root.TryGetProperty("error", out var error))
            {
                Print(Console.OpenStandardError(), bytes);
                return error.TryGetProperty("code", out var code) && code.GetString() == "invalid_arguments" ? 4 : 1;
            }
            if (!root.TryGetProperty("module_status", out _) || !root.TryGetProperty("generated_at", out _))
                throw new ConsumerException("invalid_response", "Invalid consumer response.");
            Print(Console.OpenStandardOutput(), bytes);
            return 0;
        }
        catch (ConsumerException ex) { return Fail(ex.Code, ex.Message, ex.Code == "invalid_arguments" ? 4 : ex.Code == "not_running" ? 3 : 1); }
        catch (OperationCanceledException) { return Fail("timeout", "Consumer service timed out.", 1); }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        { return Fail("connection_failed", "Could not read the consumer service response.", 1); }
    }

    internal static async Task<byte[]> Exchange(ConsumerRequest request, string? pipeName = null)
    {
        using var ct = new CancellationTokenSource(ConsumerProtocol.DeadlineMs);
        using var pipe = new NamedPipeClientStream(".", pipeName ?? ConsumerProtocol.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try { await pipe.ConnectAsync(ConsumerProtocol.DeadlineMs, ct.Token); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException) { throw new ConsumerException("not_running", "No QNotch consumer service is running for this instance."); }
        await ConsumerProtocol.WriteLine(pipe, JsonSerializer.SerializeToUtf8Bytes(request, ConsumerProtocol.Json), ct.Token);
        return await ConsumerProtocol.ReadLine(pipe, ConsumerProtocol.MaxResponse, ct.Token);
    }

    static int Fail(string code, string message, int exit) { Print(Console.OpenStandardError(), ConsumerProtocol.Failure(code, message)); return exit; }
    static void Print(Stream stream, byte[] bytes) { using (stream) { stream.Write(bytes); stream.WriteByte((byte)'\n'); } }
}
