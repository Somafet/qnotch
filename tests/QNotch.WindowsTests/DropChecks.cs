using QNotch.Modules;
using QNotch.Modules.FileTray;
using QNotch.Modules.Taildrop;

/// <summary>Drop screen targets (spec/drop-screen.md): what File tray and Taildrop offer for the dragged files, and when a tile is off.</summary>
static class DropChecks
{
    public static void Run()
    {
        // File tray: one target, off only when every dragged item is already in the tray.
        var tray = new FileTrayState();
        tray.Items.Add(new TrayItem(@"C:\Docs\a.txt"));
        string[]? added = null;
        var t = FileTrayModule.DropTarget(tray, [@"c:\docs\A.TXT"], p => added = p);
        Require(t.Id == "add" && !t.Enabled && t.Subtitle == "Already in the tray");
        t = FileTrayModule.DropTarget(tray, [@"C:\Docs\a.txt", @"C:\Docs\b.txt"], p => added = p);
        Require(t.Enabled && t.Subtitle == "Keep them within reach");
        t.Drop([@"C:\Docs\b.txt"]);
        Require(added is [@"C:\Docs\b.txt"]);
        Require(FileTrayModule.DropTarget(tray, [], _ => { }).Enabled);

        // Taildrop: one tile per device while Tailscale is ready; the reason a tile is off is its subtitle.
        var st = new TaildropState();
        (TaildropDevice Device, string[] Paths)? sent = null;
        IReadOnlyList<DropTarget> Targets(IReadOnlyList<string> files, bool folders = false) =>
            TaildropModule.DropTargets(st, files, _ => folders, (d, p) => sent = (d, p));

        Require(Targets(["a"]) is [{ Enabled: false, Title: "Checking Tailscale" }]);
        st.Set(TaildropAvailability.NotRunning, null, null, "");
        Require(Targets(["a"]) is [{ Id: "unavailable", Enabled: false, Title: "Tailscale is not running" }]);
        st.Set(TaildropAvailability.Ready, [], [], "");
        Require(Targets(["a"]) is [{ Enabled: false, Title: "No devices can receive files" }]);

        st.Set(TaildropAvailability.Ready, [new("n1", "alpha", "windows", true), new("n2", "beta", "linux", false)], [], "");
        var list = Targets(["a.txt"]);
        Require(list.Count == 2 && list[0] is { Id: "n1", Enabled: true, Subtitle: "Windows" } && list[1] is { Id: "n2", Enabled: false, Subtitle: "Offline" });
        list[0].Drop(["a.txt"]);
        Require(sent is { Device.Id: "n1", Paths: ["a.txt"] });
        Require(Targets(["dir"], folders: true).All(x => !x.Enabled) && Targets(["dir"], folders: true)[0].Subtitle == "Folders can't be sent");
        st.SetTransfer(true, "n1", "Sending a.txt", "TextSecondaryBrush", 0.2);
        Require(Targets(["a.txt"]).All(x => !x.Enabled && x.Subtitle == "Busy sending"));
        Require(Targets(["dir"], folders: true).All(x => x.Subtitle == "Folders can't be sent")); // the folder reason wins over busy
    }

    static void Require(bool condition) { if (!condition) throw new InvalidOperationException("assertion failed"); }
}
