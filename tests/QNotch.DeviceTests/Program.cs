using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QNotch.Modules.Devices;

// Native Swift integration tests start the exact transport compiled into the Windows app.
if (args is ["--serve", var serveInbox])
{
    using var server = new DeviceNode(DeviceProtocol.Id(), "Windows transport", serveInbox);
    server.Approve = _ => Task.FromResult(true);
    server.Persist = (_, _) => Task.FromResult(true);
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
    await Reject(() => b.Pair(invite.Code), "invitation single use");
    var expired = invite with { Expires = 1 };
    await Reject(() => b.Pair(expired.Code), "expired invitation");
    await a.Send(b.Id, text: "Hello Mac 👋\nárvíztűrő tükörfúrógép");
    await b.Send(a.Id, text: "Hello Windows");
    Check(File.ReadAllText(Directory.GetFiles(Path.Combine(root, "b")).Single()) == "Hello Mac 👋\nárvíztűrő tükörfúrógép", "Unicode text committed");
    Check(Directory.GetFiles(Path.Combine(root, "a")).Length == 1, "reverse text committed");
    var path = Path.Combine(root, "payload.bin"); var content = RandomNumberGenerator.GetBytes(DeviceProtocol.Chunk * 3 + 123);
    await File.WriteAllBytesAsync(path, content);
    await a.Send(b.Id, path: path); await a.Send(b.Id, path: path);
    var copies = Directory.GetFiles(Path.Combine(root, "b"), "*-payload.bin");
    Check(copies.Length == 2 && copies.All(p => File.ReadAllBytes(p).SequenceEqual(content)), "multi-chunk file and duplicate name preservation");
    await File.WriteAllBytesAsync(path, []); await b.Send(a.Id, path: path);
    Check(new FileInfo(Directory.GetFiles(Path.Combine(root, "a"), "*-payload.bin").Single()).Length == 0, "empty file");
    a.SetReceive(b.Id, false); await Reject(() => b.Send(a.Id, text: "blocked"), "receive permission"); a.SetReceive(b.Id, true);
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
