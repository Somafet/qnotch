using System.IO;
using System.Text.Json;
using QNotch.Modules;
using QNotch.Modules.Taildrop;

/// <summary>Taildrop: LocalAPI parsing, request paths, inbox name safety and set-if-changed state. No Tailscale needed.</summary>
static class TaildropChecks
{
    public static void Deterministic()
    {
        // file-targets: online first, then by name; ComputedName preferred, MagicDNS label as fallback; entries without an id are skipped.
        using (var doc = JsonDocument.Parse("""
            [
              {"Node":{"StableID":"n2","Name":"zeta.example.ts.net.","ComputedName":"zeta","Hostinfo":{"OS":"linux"},"Online":true},"PeerAPIURL":"http://100.64.0.2:1"},
              {"Node":{"StableID":"n1","Name":"alpha.example.ts.net.","ComputedName":"alpha","Hostinfo":{"OS":"windows"}},"PeerAPIURL":"http://100.64.0.1:1"},
              {"Node":{"StableID":"n3","Name":"beta.example.ts.net.","Hostinfo":{"OS":"iOS"},"Online":true}},
              {"Node":{"Name":"no-id.example.ts.net.","Online":true}},
              {"PeerAPIURL":"http://100.64.0.9:1"}
            ]
            """))
        {
            var d = TaildropClient.ParseTargets(doc.RootElement);
            Require(d.Select(x => x.Name).SequenceEqual(["beta", "zeta", "alpha"]));
            Require(d[0] == new TaildropDevice("n3", "beta", "iOS", true));
            Require(!d[2].Online && d[2].Os == "windows");
        }
        using (var doc = JsonDocument.Parse("null")) Require(TaildropClient.ParseTargets(doc.RootElement).Count == 0);

        // Inbox: null is empty, and a name that could leave the Downloads folder is never offered.
        using (var doc = JsonDocument.Parse("null")) Require(TaildropClient.ParseWaiting(doc.RootElement).Count == 0);
        using (var doc = JsonDocument.Parse("""[{"Name":"photo.jpg","Size":12},{"Name":"../evil.exe","Size":1},{"Name":"a\\b.txt"},{"Name":".."},{"Name":""},{"Name":"notes.txt"}]"""))
        {
            var w = TaildropClient.ParseWaiting(doc.RootElement);
            Require(w.SequenceEqual([new TaildropWaitingFile("photo.jpg", 12), new TaildropWaitingFile("notes.txt", 0)]));
        }
        Require(!TaildropClient.IsPlainFileName("C:\\x") && !TaildropClient.IsPlainFileName(". ") && TaildropClient.IsPlainFileName("report v2.pdf"));

        // file-put path: the id and the name are path-escaped, so a slash or percent in a name stays inside one segment.
        Require(TaildropClient.PutPath("nAbC123CNTRL", "my file/100%.txt") == "file-put/nAbC123CNTRL/my%20file%2F100%25.txt");
        Require(TaildropClient.PutPath("n1", "été.png") == "file-put/n1/%C3%A9t%C3%A9.png");

        // Saving never overwrites: the next free "name (n).ext".
        var dir = Path.Combine(Path.GetTempPath(), "qnotch-taildrop-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            Require(TaildropClient.FreePath(dir, "a.txt") == Path.Combine(dir, "a.txt"));
            File.WriteAllText(Path.Combine(dir, "a.txt"), "");
            File.WriteAllText(Path.Combine(dir, "a (2).txt.partial"), "");
            Require(TaildropClient.FreePath(dir, "a.txt") == Path.Combine(dir, "a (3).txt"));
        }
        finally { Directory.Delete(dir, true); }

        Require(TaildropClient.ParseBackendState("Running") == TaildropAvailability.Ready);
        Require(TaildropClient.ParseBackendState("Stopped") == TaildropAvailability.Stopped);
        Require(TaildropClient.ParseBackendState("NeedsLogin") == TaildropAvailability.NeedsLogin);
        Require(TaildropClient.ParseBackendState(null) == TaildropAvailability.NotRunning);

        // State raises its events only when something differs.
        var st = new TaildropState();
        int changed = 0, transfer = 0;
        st.Changed += () => changed++;
        st.TransferChanged += () => transfer++;
        TaildropDevice[] devices = [new("n1", "alpha", "windows", true)];
        st.Set(TaildropAvailability.Ready, devices, [], "");
        st.Set(TaildropAvailability.Ready, [new("n1", "alpha", "windows", true)], [], "");
        st.Set(TaildropAvailability.Ready, null, null, ""); // a failed read keeps the lists
        Require(changed == 1 && st.Devices.Count == 1);
        st.Set(TaildropAvailability.NotRunning, null, null, "");
        Require(changed == 2 && st.Devices.Count == 0);
        st.SetTransfer(true, "n1", "Sending a", "TextSecondaryBrush", 0.5);
        st.SetTransfer(true, "n1", "Sending a", "TextSecondaryBrush", 0.5);
        st.SetTransfer(false, null, "Saved", "SuccessBrush", -1, @"C:\d\a.txt");
        st.SetTransfer(false, null, "Saved", "SuccessBrush", -1);
        Require(transfer == 2 && st.Saved == @"C:\d\a.txt");
        st.SetTransfer(true, null, "Saving", "TextSecondaryBrush", -1);
        Require(st.Saved is null);

        var info = ModuleList.All.Single(m => m.Id == "taildrop");
        Require(info.Shared is null && !info.Early && ModuleList.TourGroups.Count(g => g.Ids.Contains("taildrop")) == 1);
        // Off by default: it needs Tailscale. A fresh install leaves it off; turning it on is a local choice.
        var gs = new QNotch.Core.GeneralSettings();
        Require(!info.DefaultEnabled && !info.IsEnabled(gs));
        info.SetEnabled(gs, true);
        Require(info.IsEnabled(gs) && gs.LocalEnabledModules.Contains("taildrop"));
    }

    /// <summary>Read-only check against the Tailscale service on this machine (<c>--taildrop-live</c>): nothing is sent or saved.</summary>
    public static async Task Live()
    {
        using var client = new TaildropClient();
        var state = await client.GetAvailabilityAsync(default);
        Console.WriteLine($"Taildrop live: {state}");
        if (state != TaildropAvailability.Ready) return;
        var targets = await client.GetTargetsAsync(default);
        var waiting = await client.GetWaitingAsync(default);
        Console.WriteLine($"Taildrop live: {targets.Count} targets ({targets.Count(t => t.Online)} online), {waiting.Count} waiting");
        Require(targets.All(t => t.Id.Length > 0 && t.Name.Length > 0));
    }

    static void Require(bool condition) { if (!condition) throw new InvalidOperationException("assertion failed"); }
}
