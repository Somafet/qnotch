using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace QNotch.Core.Consumers;

/// <summary>Bounded one-request connections. No timers or work while no client is connected.</summary>
internal sealed class ConsumerHost : IDisposable
{
    readonly Func<ConsumerRequest, CancellationToken, Task<ConsumerSnapshot>> _capture;
    readonly CancellationTokenSource _stop = new();
    readonly HashSet<Stream> _open = [];
    readonly string _pipeName;
    readonly Task[] _workers;
    public Task Completion => Task.WhenAll(_workers);

    public ConsumerHost(Func<ConsumerRequest, CancellationToken, Task<ConsumerSnapshot>> capture, string? pipeName = null)
    {
        _capture = capture;
        _pipeName = pipeName ?? ConsumerProtocol.PipeName;
        // Create synchronously so startup detects ACL/name errors. First-instance prevents hijacking an existing pipe.
        var first = Listen(true);
        _workers = Enumerable.Range(0, ConsumerProtocol.MaxClients).Select(i => Task.Run(() => Loop(i == 0 ? first : null))).ToArray();
    }

    async Task Loop(NamedPipeServerStream? pipe)
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                pipe ??= Listen(false);
                lock (_open) _open.Add(pipe);
                try
                {
                    await pipe.WaitForConnectionAsync(_stop.Token);
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
                    deadline.CancelAfter(ConsumerProtocol.DeadlineMs);
                    await Serve(pipe, deadline.Token);
                }
                catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
                finally { lock (_open) _open.Remove(pipe); pipe.Dispose(); pipe = null; }
            }
        }
        catch (Exception ex) when (_stop.IsCancellationRequested && ex is ObjectDisposedException or OperationCanceledException or IOException) { }
        catch (Exception ex) { Log.Warn("Consumer listener stopped", ex); }
        finally { pipe?.Dispose(); }
    }

    async Task Serve(Stream pipe, CancellationToken ct)
    {
        byte[] response;
        try
        {
            var bytes = await ConsumerProtocol.ReadLine(pipe, ConsumerProtocol.MaxRequest, ct);
            var request = JsonSerializer.Deserialize<ConsumerRequest>(bytes, ConsumerProtocol.Json)
                ?? throw new ConsumerException("invalid_arguments", "Expected a consumer request.");
            ConsumerProtocol.Validate(request);
            var snapshot = await _capture(request, ct);
            ct.ThrowIfCancellationRequested();
            using var buffer = new ResponseBuffer();
            await JsonSerializer.SerializeAsync(buffer, new ConsumerEnvelope(ConsumerProtocol.Version,
                typeof(ConsumerHost).Assembly.GetName().Version?.ToString(3) ?? "unknown", "Windows", DateTime.UtcNow, snapshot.ModuleStatus, snapshot.Data), ConsumerProtocol.Json, ct);
            response = buffer.ToArray();
        }
        catch (ConsumerException ex) { response = ConsumerProtocol.Failure(ex.Code, ex.Message); }
        catch (JsonException) { response = ConsumerProtocol.Failure("invalid_arguments", "Malformed consumer request."); }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { response = ConsumerProtocol.Failure("internal_error", "Snapshot is unavailable."); }
        await ConsumerProtocol.WriteLine(pipe, response, ct);
    }

    public void Dispose()
    {
        _stop.Cancel();
        lock (_open) foreach (var stream in _open) stream.Dispose();
    }

    sealed class ResponseBuffer : MemoryStream
    {
        void Check(int count)
        {
            if (Length + count > ConsumerProtocol.MaxResponse) throw new ConsumerException("size_limit", "Snapshot exceeds the response size limit.");
        }
        public override void Write(byte[] buffer, int offset, int count) { Check(count); base.Write(buffer, offset, count); }
        public override void Write(ReadOnlySpan<byte> buffer) { Check(buffer.Length); base.Write(buffer); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        { Check(buffer.Length); base.Write(buffer.Span); return ValueTask.CompletedTask; }
    }

    // NamedPipeServerStream's default flags allow remote clients. Create the handle with PIPE_REJECT_REMOTE_CLIENTS
    // and an explicit protected DACL for the current user, then let .NET own asynchronous I/O and handle lifetime.
    NamedPipeServerStream Listen(bool first)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value ?? throw new InvalidOperationException("Current user has no SID.");
        // Elevated tokens may default object ownership to Administrators. Set the actual user owner
        // explicitly so the client can verify that exact SID, independently of the default token owner.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor($"O:{sid}D:P(A;;GA;;;{sid})", 1, out var descriptor, out _)) throw new Win32Exception();
        try
        {
            var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
            var handle = CreateNamedPipe(@"\\.\pipe\" + _pipeName, 3 | 0x40000000u | (first ? 0x80000u : 0), 8,
                ConsumerProtocol.MaxClients, 8192, 4096, 0, ref security);
            if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
            try { return new NamedPipeServerStream(PipeDirection.InOut, true, false, handle); }
            catch { handle.Dispose(); throw; }
        }
        finally { LocalFree(descriptor); }
    }

    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public nint Descriptor; public int Inherit; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafePipeHandle CreateNamedPipe(string name, uint openMode, uint pipeMode, int maxInstances, int outBuffer, int inBuffer, int timeout, ref SecurityAttributes security);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string descriptor, uint revision, out nint security, out uint size);
    [DllImport("kernel32.dll")] static extern nint LocalFree(nint memory);
}
