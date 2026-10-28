using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QNotch.Modules.Devices;

if (args is ["--send", var invitationCode, var sendPath])
{
    using var client = new DeviceNode(DeviceProtocol.Id(), "Windows client", Path.Combine(Path.GetTempPath(), DeviceProtocol.Id()));
    client.Persist = (_, _) => Task.FromResult(true);
    client.Start(0, IPAddress.Loopback);
    await client.Pair(invitationCode);
    await client.Send(client.Peers.Single().Id, text: "Windows → Mac 👋");
    await client.Send(client.Peers.Single().Id, path: sendPath);
    return;
}

// Native Swift integration tests start the exact transport compiled into the Windows app.
if (args is ["--serve", var serveInbox])
{
    using var server = new DeviceNode(DeviceProtocol.Id(), "Windows transport", serveInbox);
    server.Approve = _ => Task.FromResult(true);
    server.Persist = (_, _) => Task.FromResult(true);
    var serverSync = new DeviceSync(server.Id, new());
    server.Exchange = (_, input) =>
    {
        var incoming = DeviceProtocol.Decode<SyncBundle>(input);
        if (incoming.NotesEnabled) { serverSync.ReceiveNotes(incoming.Notes); serverSync.EditNote("Windows read the native note"); }
        if (incoming.ClipboardEnabled) { serverSync.ReceiveClipboard(incoming.Clipboard); serverSync.CopyText("Windows clipboard reply"); }
        return Task.FromResult(DeviceProtocol.Encode(serverSync.Bundle(incoming.NotesEnabled, incoming.ClipboardEnabled)));
    };
    server.Received = (sender, path, file) => _ = Task.Run(async () =>
    {
        try { await server.Send(server.Peers.Single().Id, text: file ? null : await File.ReadAllTextAsync(path), path: file ? path : null); }
        catch { /* Test timeout reports an echo failure. */ }
    });
    server.Start(0, IPAddress.Loopback); Console.WriteLine(server.Invite("127.0.0.1").Code);
    await Task.Delay(TimeSpan.FromMinutes(3)); return;
}

var checks = 0;
void Check(bool condition, string title) { if (!condition) throw new Exception(title); checks++; Console.WriteLine("ok " + title); }
async Task Reject(Func<Task> action, string title)
{
    try { await action(); } catch (Exception ex) when (ex is IOException or CryptographicException or SocketException or OperationCanceledException or FormatException) { Check(true, title); return; }
    throw new Exception("Expected rejection: " + title);
}
var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "wire-v1.json"))).RootElement;
byte[] Bytes(string key) => Convert.FromHexString(fixture.GetProperty(key).GetString()!);
var derived = DeviceProtocol.ConnectionKey(Bytes("secret"), Bytes("challenge"), Bytes("hello"));
Check(derived.SequenceEqual(Bytes("key")), "independent Node.js HMAC vector");
Check(!DeviceProtocol.ConnectionKey(Bytes("secret"), Bytes("challenge"), DeviceProtocol.Encode(new DeviceHello(1, DeviceProtocol.Id(), false,
    Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))))).SequenceEqual(derived), "fresh client hello prevents server-ack replay");
var aad = DeviceProtocol.Aad(Bytes("challenge"), 0, 0);
Check(aad.SequenceEqual(Bytes("aad")), "AAD format");
var box = DeviceProtocol.Seal(derived, Bytes("plain"), aad, Bytes("nonce"));
Check(box.SequenceEqual(Bytes("box")), "independent Node.js AES-GCM vector");
Check(DeviceProtocol.Open(derived, box, aad).SequenceEqual(Bytes("plain")), "decrypt shared vector");
await Reject(() => Task.Run(() => DeviceProtocol.Open(derived, box, DeviceProtocol.Aad(Bytes("challenge"), 1, 0))), "reject reflected frame");
await Reject(() => Task.Run(() => DeviceProtocol.Open(derived, box, DeviceProtocol.Aad(Bytes("challenge"), 0, 1))), "reject reordered frame");
box[^1] ^= 1;
await Reject(() => Task.Run(() => DeviceProtocol.Open(derived, box, aad)), "reject tampered tag");
foreach (var invalid in new[] { "", "..", "../escape", "a\\b", "CON.txt", "LPT9", "a:", "x.", "x ", "a\0b" })
    await Reject(() => Task.Run(() => DeviceProtocol.ValidateName(invalid)), "unsafe name " + invalid.Replace('\0', '?'));
Check(DeviceProtocol.LocalAddress("192.168.1.20") && !DeviceProtocol.LocalAddress("8.8.8.8"), "LAN address policy");
Check(DeviceProtocol.LocalAddress("100.64.0.1") && DeviceProtocol.LocalAddress("100.127.255.254") && !DeviceProtocol.LocalAddress("100.128.0.1"), "Tailscale address boundaries");
var syncFixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "sync-v1.json"))).RootElement;
NoteRevision Revision(string key) => DeviceProtocol.Decode<NoteRevision>(Encoding.UTF8.GetBytes(syncFixture.GetProperty(key).GetRawText()));
var concurrent = DeviceSync.Merge([Revision("base"), Revision("windows")], [Revision("mac")]);
Check(concurrent.Count == 2 && concurrent.Select(i => i.Text).ToHashSet().SetEquals(["Edited on Windows", "Edited on Mac"]), "offline edits preserve both note versions");
Check(DeviceSync.Merge(concurrent, concurrent).SequenceEqual(concurrent), "duplicate note sync is idempotent");
var deleted = DeviceSync.Merge(concurrent, [Revision("resolvedDeletion")]);
Check(deleted.Count == 1 && deleted[0].Text == "", "explicit deletion resolves both conflicting branches");
Check(DeviceSync.Merge(deleted, [Revision("base"), Revision("windows"), Revision("mac")]).Single().Text == "", "stale replay cannot revive deleted note text");
await Reject(() => Task.Run(() => DeviceSync.Merge([Revision("base")], [Revision("base") with { Text = "tampered" }])), "reject revision identity mutation");
var journal = new SyncJournal { Notes = concurrent, ActiveClock = new(Revision("windows").Clock) };
var register = new DeviceSync("00000000-0000-0000-0000-000000000001", journal);
register.EditNote("Continue editing locally");
Check(register.Notes.Count == 2 && register.Notes.Any(i => i.Text == "Edited on Mac"), "editing through a conflict does not discard remote branch");
register.EditNote("Chosen resolution", resolveAll: true);
Check(register.Notes.Count == 1 && register.Notes[0].Text == "Chosen resolution", "user resolution advances every causal branch");
register.CopyText("Sensitive clipboard example");
var clipboardVersion = register.Clipboard;
Check(register.ReceiveClipboard(clipboardVersion) is null, "clipboard echo is suppressed");
var serializedJournal = Encoding.UTF8.GetString(DeviceProtocol.Encode(journal));
Check(!serializedJournal.Contains("Sensitive clipboard example", StringComparison.Ordinal), "clipboard text is never journaled to disk");
var restartedSync = new DeviceSync("00000000-0000-0000-0000-000000000001", DeviceProtocol.Decode<SyncJournal>(DeviceProtocol.Encode(journal)));
Check(restartedSync.ReceiveClipboard(clipboardVersion) is null, "clipboard replay remains suppressed after restart");
var recoveredSync = new DeviceSync("00000000-0000-0000-0000-000000000001", DeviceProtocol.Decode<SyncJournal>(DeviceProtocol.Encode(journal)));
recoveredSync.ReconcileEditor("Different note file after a crash");
Check(recoveredSync.Notes.Count == 2 && recoveredSync.Notes.Any(i => i.Text == "Chosen resolution"), "journal/file mismatch recovers both copies as a conflict");

var root = Path.Combine(Path.GetTempPath(), "qnotch-devices-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
try
{
    using var a = new DeviceNode(DeviceProtocol.Id(), "Windows A", Path.Combine(root, "a"));
    using var b = new DeviceNode(DeviceProtocol.Id(), "Windows B", Path.Combine(root, "b"));
    var persisted = new Dictionary<string, (DevicePeer, byte[])>();
    a.Approve = _ => Task.FromResult(true); b.Approve = _ => Task.FromResult(false);
    a.Persist = (p, key) => { persisted[p.Id] = (p, key); return Task.FromResult(true); };
    b.Persist = (_, _) => Task.FromResult(true);
    a.Start(0, IPAddress.Loopback); b.Start(0, IPAddress.Loopback);
    await Reject(() => a.Pair(b.Invite("127.0.0.1").Code), "host declines pairing");
    var invite = a.Invite("127.0.0.1");
    await b.Pair(invite.Code);
    Check(a.Peers.Length == 1 && b.Peers.Length == 1, "approved bidirectional pairing");
    using var c = new DeviceNode(DeviceProtocol.Id(), "Unpaired device", Path.Combine(root, "c"));
    c.Start(0, IPAddress.Loopback); c.Persist = (_, _) => Task.FromResult(true);
    await Reject(() => c.Pair(invite.Code), "invitation single use for an unpaired device");
    var expired = invite with { Expires = 1 };
    await Reject(() => b.Pair(expired.Code), "expired invitation");
    await a.Send(b.Id, text: "Hello Mac 👋\nárvíztűrő tükörfúrógép");
    await b.Send(a.Id, text: "Hello Windows");
    Check(File.ReadAllText(Directory.GetFiles(Path.Combine(root, "b")).Single()) == "Hello Mac 👋\nárvíztűrő tükörfúrógép", "Unicode text committed");
    Check(Directory.GetFiles(Path.Combine(root, "a")).Length == 1, "reverse text committed");
    var originalPeer = b.Peers.Single();
    b.Restore(originalPeer, RandomNumberGenerator.GetBytes(32));
    await Reject(() => b.Send(a.Id, text: "wrong key"), "reject incorrect peer key");
    b.Restore(originalPeer, persisted[b.Id].Item2);
    var syncA = new DeviceSync(a.Id, new()); var syncB = new DeviceSync(b.Id, new());
    syncA.EditNote(new string('a', DeviceProtocol.Chunk + 50));
    a.Exchange = (_, input) =>
    {
        var incoming = DeviceProtocol.Decode<SyncBundle>(input); syncA.ReceiveNotes(incoming.Notes);
        return Task.FromResult(DeviceProtocol.Encode(syncA.Bundle(true, false)));
    };
    var pulled = DeviceProtocol.Decode<SyncBundle>(await b.Synchronize(a.Id, DeviceProtocol.Encode(syncB.Bundle(true, false))));
    Check(syncB.ReceiveNotes(pulled.Notes)?.Length == DeviceProtocol.Chunk + 50, "encrypted sync streams notes larger than one frame");
    syncA.EditNote("Offline Windows edit"); syncB.EditNote("Offline other-device edit");
    var reconciled = DeviceProtocol.Decode<SyncBundle>(await b.Synchronize(a.Id, DeviceProtocol.Encode(syncB.Bundle(true, false))));
    Check(syncB.ReceiveNotes(reconciled.Notes) is null && syncA.Notes.Count == 2 && syncB.Notes.Count == 2, "socket reconciliation preserves concurrent offline changes");
    var path = Path.Combine(root, "payload.bin"); var content = RandomNumberGenerator.GetBytes(DeviceProtocol.Chunk * 3 + 123);
    await File.WriteAllBytesAsync(path, content);
    await a.Send(b.Id, path: path); await a.Send(b.Id, path: path);
    var copies = Directory.GetFiles(Path.Combine(root, "b"), "*-payload.bin");
    Check(copies.Length == 2 && copies.All(p => File.ReadAllBytes(p).SequenceEqual(content)), "multi-chunk file and duplicate name preservation");
    await File.WriteAllBytesAsync(path, []); await b.Send(a.Id, path: path);
    Check(new FileInfo(Directory.GetFiles(Path.Combine(root, "a"), "*-payload.bin").Single()).Length == 0, "empty file");
    a.SetReceive(b.Id, false); await Reject(() => b.Send(a.Id, text: "blocked"), "receive permission"); a.SetReceive(b.Id, true);
    // Send a valid authenticated offer, then close midway through its declared payload.
    using (var truncated = new TcpClient())
    {
        await truncated.ConnectAsync("127.0.0.1", a.Port);
        var stream = truncated.GetStream();
        var hello = DeviceProtocol.Encode(new DeviceHello(1, b.Id, false, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))));
        await DeviceProtocol.WritePacket(stream, hello, CancellationToken.None);
        var challenge = new byte[32]; await stream.ReadExactlyAsync(challenge);
        var channel = new DeviceChannel(stream, DeviceProtocol.ConnectionKey(persisted[b.Id].Item2, challenge, hello), challenge, true, CancellationToken.None);
        await channel.Send(DeviceProtocol.Encode(new DeviceMessage("file", Name: "interrupted.bin", Size: 100)));
        await channel.CheckReply(); await channel.Send([1, 2, 3]);
    }
    for (var attempt = 0; attempt < 100 && Directory.GetFiles(root, "*.part", SearchOption.AllDirectories).Any(); attempt++) await Task.Delay(10);
    Check(!Directory.GetFiles(Path.Combine(root, "a"), "*interrupted.bin").Any() && !Directory.GetFiles(root, "*.part", SearchOption.AllDirectories).Any(), "truncated transfer is removed");
    using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    await Reject(() => b.Send(a.Id, text: "cancelled", ct: cancelled.Token), "cancelled send");
    Check(!Directory.GetFiles(root, "*.part", SearchOption.AllDirectories).Any(), "no partial files after checks");
    // A restarted transport can authenticate using only persisted metadata and the credential-store key.
    using var restored = new DeviceNode(a.Id, "Windows A restarted", Path.Combine(root, "restored"));
    var saved = persisted[b.Id]; restored.Restore(saved.Item1, saved.Item2); restored.Start(0, IPAddress.Loopback);
    var bp = b.Peers.Single(); b.Restore(bp with { Port = restored.Port }, saved.Item2);
    await b.Send(a.Id, text: "after restart");
    Check(Directory.GetFiles(Path.Combine(root, "restored")).Length == 1, "restored trust works after restart");
    restored.Remove(b.Id); await Reject(() => b.Send(a.Id, text: "unpaired"), "revoked trust");
}
finally { Directory.Delete(root, true); }
Console.WriteLine($"{checks} device checks passed.");
