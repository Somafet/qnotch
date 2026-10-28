using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace QNotch.Modules.Devices;

/// <summary>One native peer's transport. No UI dependencies, polling, disk settings or global state.</summary>
public sealed class DeviceNode(string id, string name, string inbox) : IDisposable
{
    readonly ConcurrentDictionary<string, (DevicePeer Peer, byte[] Key)> peers = new();
    readonly ConcurrentDictionary<TcpClient, byte> connections = new();
    readonly CancellationTokenSource stopping = new();
    readonly SemaphoreSlim slots = new(4);
    TcpListener? listener;
    DeviceInvitation? invitation;
    int pairing;
    readonly Queue<long> pairingAttempts = new();
    readonly object partialGate = new();
    readonly HashSet<string> partialFiles = [];
    public string Id => id;
    public int Port => (listener?.LocalEndpoint as IPEndPoint)?.Port ?? 0;
    public DevicePeer[] Peers => peers.Values.Select(p => p.Peer).OrderBy(p => p.Name).ToArray();
    public Func<DevicePeer, Task<bool>> Approve { get; set; } = _ => Task.FromResult(false);
    public Func<DevicePeer, byte[], Task<bool>> Persist { get; set; } = (_, _) => Task.FromResult(false);
    public Action<string, string, bool>? Received { get; set; }
    public Action<string, long, long>? IncomingProgress { get; set; }
    public Action<string>? IncomingFailed { get; set; }
    public Action? Changed { get; set; }
    public Func<string, byte[], Task<byte[]>>? Exchange { get; set; }
    public void Restore(DevicePeer peer, byte[] key) { if (key.Length == 32) peers[peer.Id] = (peer, key); }
    public void Remove(string peerId)
    {
        peers.TryRemove(peerId, out _);
        // Revocation also ends already-authenticated transfers.
        foreach (var client in connections.Keys) client.Dispose();
        Changed?.Invoke();
    }
    public void SetReceive(string peerId, bool receive)
    {
        if (peers.TryGetValue(peerId, out var p)) peers[peerId] = (p.Peer with { Receive = receive }, p.Key);
        if (!receive) foreach (var client in connections.Keys) client.Dispose();
    }
    public void SetSync(string peerId, bool notes, bool clipboard)
    {
        if (peers.TryGetValue(peerId, out var p)) peers[peerId] = (p.Peer with { SyncNotes = notes, SyncClipboard = clipboard }, p.Key);
    }
    public void Start(int port = 45874, IPAddress? bind = null)
    {
        listener = new TcpListener(bind ?? IPAddress.Any, port); listener.Start(); _ = Accept();
    }
    public DeviceInvitation Invite(string host)
    {
        if (Port == 0 || !DeviceProtocol.LocalAddress(host)) throw new IOException("Enable sharing and choose a local IPv4 address.");
        return invitation = new(1, id, name, host, Port, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), DateTimeOffset.UtcNow.AddMinutes(5).ToUnixTimeSeconds());
    }
    bool AllowPairAttempt()
    {
        lock (pairingAttempts)
        {
            var now = Environment.TickCount64;
            while (pairingAttempts.TryPeek(out var time) && now - time >= 60000) pairingAttempts.Dequeue();
            if (pairingAttempts.Count >= 5) return false;
            pairingAttempts.Enqueue(now); return true;
        }
    }
    FileStream CreatePartial(string path, CancellationToken ct)
    {
        lock (partialGate)
        {
            ct.ThrowIfCancellationRequested();
            var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Delete, DeviceProtocol.Chunk, true);
            partialFiles.Add(path); return file;
        }
    }
    void DiscardPartial(string path)
    {
        lock (partialGate) { if (File.Exists(path)) File.Delete(path); partialFiles.Remove(path); }
    }
    async Task Accept()
    {
        try
        {
            while (!stopping.IsCancellationRequested)
            {
                var client = await listener!.AcceptTcpClientAsync(stopping.Token);
                if (!slots.Wait(0)) { client.Dispose(); continue; }
                connections[client] = 0;
                _ = Task.Run(async () =>
                {
                    try { await Serve(client); }
                    catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or CryptographicException or System.Text.Json.JsonException or FormatException or ArgumentException or ObjectDisposedException) { /* Untrusted input: close without logging payloads. */ }
                    finally { connections.TryRemove(client, out _); client.Dispose(); slots.Release(); }
                });
            }
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException or ObjectDisposedException) { }
    }
    async Task Serve(TcpClient client)
    {
        if (client.Client.RemoteEndPoint is not IPEndPoint remote || !DeviceProtocol.LocalAddress(remote.Address.ToString())) return;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(10)); // Unauthenticated connections cannot occupy a slot for two minutes.
        var stream = client.GetStream();
        var helloBytes = await DeviceProtocol.ReadPacket(stream, 1024, timeout.Token);
        var hello = DeviceProtocol.Decode<DeviceHello>(helloBytes);
        if (hello.V != 1 || !DeviceProtocol.ValidId(hello.Id) || hello.Id == id || Convert.FromBase64String(hello.Nonce).Length != 32) return;
        var invite = invitation;
        byte[] secret;
        if (hello.Pair)
        {
            if (invite is null || invite.Expires <= DateTimeOffset.UtcNow.ToUnixTimeSeconds() || !AllowPairAttempt() || Interlocked.CompareExchange(ref pairing, 1, 0) != 0) return;
            secret = Convert.FromBase64String(invite.Secret);
        }
        else
        {
            if (!peers.TryGetValue(hello.Id, out var peer)) return;
            secret = peer.Key;
        }
        try
        {
            var challenge = RandomNumberGenerator.GetBytes(32); await stream.WriteAsync(challenge, timeout.Token);
            var channel = new DeviceChannel(stream, DeviceProtocol.ConnectionKey(secret, challenge, helloBytes), challenge, false, timeout.Token);
            var message = DeviceProtocol.Decode<DeviceMessage>(await channel.Read());
            timeout.CancelAfter(TimeSpan.FromMinutes(2));
            if (hello.Pair)
            {
                if (message.Op != "pair" || message.Id != hello.Id || message.Name is not { Length: > 0 and <= 80 } || message.Port is < 1 or > 65535) return;
                var key = Convert.FromBase64String(message.Key); if (key.Length != 32 || peers.ContainsKey(hello.Id)) return;
                var peer = new DevicePeer(hello.Id, message.Name, remote.Address.ToString(), message.Port);
                if (!await Approve(peer).WaitAsync(timeout.Token) || invitation != invite || invite!.Expires <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
                { await channel.Reply(new(false, "Pairing was declined or expired.")); return; }
                stopping.Token.ThrowIfCancellationRequested();
                if (peers.Count >= 20 || !await Persist(peer, key)) { await channel.Reply(new(false, "Could not save device trust.")); return; }
                stopping.Token.ThrowIfCancellationRequested();
                peers[peer.Id] = (peer, key); invitation = null; Changed?.Invoke();
                await channel.Reply(new(true, Id: id, Name: name)); return;
            }
            // Re-check trust at the point of accepting data, including after an unpair.
            if (!peers.TryGetValue(hello.Id, out var trusted) || !trusted.Peer.Receive) { await channel.Reply(new(false, "Receiving from this device is off.")); return; }
            if (message.Op == "ping") { await channel.Reply(new(true)); return; }
            if (message.Op == "sync")
            {
                if (Exchange is null || message.Size is < 1 or > DeviceProtocol.MaxSync) { await channel.Reply(new(false, "Synchronization is unavailable.")); return; }
                await channel.Reply(new(true));
                var input = await channel.ReadBytes(message.Size);
                if (!peers.TryGetValue(hello.Id, out var active) || !active.Peer.Receive) return;
                var output = await Exchange(hello.Id, input).WaitAsync(timeout.Token);
                if (output.Length is < 1 or > DeviceProtocol.MaxSync) throw new IOException("Synchronization response too large.");
                await channel.Reply(new(true, Size: output.Length)); await channel.SendBytes(output); return;
            }
            if (message.Op == "text" && message.Text is { Length: <= 16000 })
            {
                var path = Path.Combine(inbox, Guid.NewGuid().ToString("N") + "-text.txt");
                try
                {
                    Directory.CreateDirectory(inbox);
                    await using (var output = CreatePartial(path + ".part", timeout.Token))
                        await output.WriteAsync(System.Text.Encoding.UTF8.GetBytes(message.Text), timeout.Token);
                    timeout.Token.ThrowIfCancellationRequested();
                    if (!peers.TryGetValue(hello.Id, out var current) || !current.Peer.Receive) throw new IOException("Receiving ended.");
                    File.Move(path + ".part", path);
                }
                catch { IncomingFailed?.Invoke(trusted.Peer.Name); throw; }
                finally { DiscardPartial(path + ".part"); }
                Received?.Invoke(trusted.Peer.Name, path, false); await channel.Reply(new(true)); return;
            }
            if (message.Op != "file" || message.Size < 0 || message.Size > DeviceProtocol.MaxFile) { await channel.Reply(new(false, "Unsupported request.")); return; }
            DeviceProtocol.ValidateName(message.Name);
            var target = Path.Combine(inbox, Guid.NewGuid().ToString("N") + "-" + message.Name);
            var part = target + ".part";
            try
            {
                Directory.CreateDirectory(inbox);
                IncomingProgress?.Invoke(trusted.Peer.Name, 0, message.Size);
                var progressAt = Environment.TickCount64;
                await using (var file = CreatePartial(part, timeout.Token))
                {
                    await channel.Reply(new(true));
                    long count = 0;
                    while (count < message.Size)
                    {
                        timeout.CancelAfter(TimeSpan.FromSeconds(30));
                        var bytes = await channel.Read();
                        if (bytes.Length == 0 || bytes.Length > message.Size - count || !peers.ContainsKey(hello.Id)) throw new IOException("Transfer ended.");
                        await file.WriteAsync(bytes, timeout.Token); count += bytes.Length;
                        if (Environment.TickCount64 - progressAt >= 250)
                        { progressAt = Environment.TickCount64; IncomingProgress?.Invoke(trusted.Peer.Name, count, message.Size); }
                    }
                    await file.FlushAsync(timeout.Token);
                }
                timeout.Token.ThrowIfCancellationRequested();
                if (!peers.TryGetValue(hello.Id, out var current) || !current.Peer.Receive) throw new IOException("Receiving ended.");
                File.Move(part, target); Received?.Invoke(trusted.Peer.Name, target, true); await channel.Reply(new(true));
            }
            catch { IncomingFailed?.Invoke(trusted.Peer.Name); throw; }
            finally { DiscardPartial(part); }
        }
        finally { if (hello.Pair) Interlocked.Exchange(ref pairing, 0); }
    }
    async Task Use(DevicePeer peer, byte[] key, bool pair, Func<DeviceChannel, Task> action, CancellationToken ct)
    {
        if (Port == 0 || !DeviceProtocol.LocalAddress(peer.Host) || peer.Port is < 1 or > 65535) throw new IOException("Enable sharing and check the device address.");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, stopping.Token);
        linked.CancelAfter(TimeSpan.FromMinutes(2));
        using var client = new TcpClient(); connections[client] = 0;
        try
        {
            await client.ConnectAsync(peer.Host, peer.Port, linked.Token);
            var stream = client.GetStream(); var hello = DeviceProtocol.Encode(new DeviceHello(1, id, pair, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))));
            await DeviceProtocol.WritePacket(stream, hello, linked.Token);
            var challenge = new byte[32]; await stream.ReadExactlyAsync(challenge, linked.Token);
            await action(new DeviceChannel(stream, DeviceProtocol.ConnectionKey(key, challenge, hello), challenge, true, linked.Token));
        }
        finally { connections.TryRemove(client, out _); }
    }
    public async Task Pair(string code, CancellationToken ct = default)
    {
        var invite = DeviceInvitation.Parse(code);
        if (invite.Id == id || peers.ContainsKey(invite.Id) || peers.Count >= 20) throw new IOException("Cannot add this device. Remove an existing pairing before pairing again.");
        var key = RandomNumberGenerator.GetBytes(32);
        await Use(new(invite.Id, invite.Name, invite.Host, invite.Port), Convert.FromBase64String(invite.Secret), true, async channel =>
        {
            await channel.Send(DeviceProtocol.Encode(new DeviceMessage("pair", id, name, Port, Convert.ToBase64String(key))));
            var reply = DeviceProtocol.Decode<DeviceReply>(await channel.Read());
            if (!reply.Ok || reply.Id != invite.Id) throw new IOException("Pairing was declined or expired.");
            var peer = new DevicePeer(invite.Id, invite.Name, invite.Host, invite.Port);
            if (!await Persist(peer, key)) throw new IOException("Could not save device trust. Remove the device and pair again.");
            peers[peer.Id] = (peer, key); Changed?.Invoke();
        }, ct);
    }
    public async Task Send(string peerId, string? text = null, string? path = null, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        if (!peers.TryGetValue(peerId, out var p)) throw new IOException("Device is no longer paired.");
        await Use(p.Peer, p.Key, false, async channel =>
        {
            if (path is null)
            {
                if (text?.Length > 16000) throw new IOException("Text is too long.");
                await channel.Send(DeviceProtocol.Encode(new DeviceMessage(text is null ? "ping" : "text", Text: text ?? "")));
                await channel.CheckReply(); return;
            }
            await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, DeviceProtocol.Chunk, true);
            var size = file.Length; DeviceProtocol.ValidateName(Path.GetFileName(path));
            if (size > DeviceProtocol.MaxFile) throw new IOException("Files must be at most 2 GiB.");
            await channel.Send(DeviceProtocol.Encode(new DeviceMessage("file", Name: Path.GetFileName(path), Size: size)));
            await channel.CheckReply();
            var buffer = new byte[DeviceProtocol.Chunk]; long sent = 0;
            while (sent < size)
            {
                var n = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, size - sent)), ct);
                if (n == 0) throw new IOException("File changed during transfer.");
                await channel.Send(buffer[..n]); sent += n; progress?.Invoke(sent, size);
            }
            await channel.CheckReply();
        }, ct);
    }
    public async Task<byte[]> Synchronize(string peerId, byte[] payload, CancellationToken ct = default)
    {
        if (payload.Length is < 1 or > DeviceProtocol.MaxSync || !peers.TryGetValue(peerId, out var peer)) throw new IOException("Synchronization is unavailable.");
        byte[] result = [];
        await Use(peer.Peer, peer.Key, false, async channel =>
        {
            await channel.Send(DeviceProtocol.Encode(new DeviceMessage("sync", Size: payload.Length)));
            await channel.CheckReply(); await channel.SendBytes(payload);
            var response = DeviceProtocol.Decode<DeviceReply>(await channel.Read());
            if (!response.Ok) throw new IOException("Synchronization was declined.");
            result = await channel.ReadBytes(response.Size);
        }, ct);
        return result;
    }
    public void Dispose()
    {
        invitation = null; stopping.Cancel(); listener?.Stop(); listener = null;
        foreach (var client in connections.Keys) client.Dispose();
        // Mark open receive files for deletion before the UI can exit. FileShare.Delete lets
        // Windows finish deletion when the process closes a still-unwinding file handle.
        lock (partialGate)
            foreach (var path in partialFiles.ToArray())
                try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
