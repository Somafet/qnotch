using System.Collections;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Xml;
using QNotch.Core;

namespace QNotch.Modules.Scheduled;

/// <summary>One task of the Windows Task Scheduler root folder, with text ready to render.</summary>
internal sealed record SchedTask(string Name, bool Enabled, bool Running, string Schedule, DateTime? Next, DateTime? Last, int Result)
{
    // 0x413xx are scheduler status codes (ready, running, not yet run, queued), not failures.
    public bool Failed => Last is not null && Result != 0 && (Result & 0xFFFFFF00) != 0x41300;

    public string Meta
    {
        get
        {
            var parts = new List<string> { Running ? "Running now" : Enabled ? Schedule : "Paused" };
            if (Enabled && Next is { } n) parts.Add("next " + When(n));
            if (Last is { } l) parts.Add((Failed ? "failed " : "last run ") + When(l));
            return string.Join(" · ", parts);
        }
    }

    public string Short => !Enabled ? "Paused" : Next is { } n ? When(n) : Schedule;

    static string When(DateTime d) => d.Date == DateTime.Today ? d.ToString("t") : d.ToString("MMM d, ", UiCulture.Value) + d.ToString("t");
}

/// <summary>
/// The Task Scheduler COM API (Schedule.Service), late bound: no interop assembly, no package. Thread pool only.
/// Lists the root folder and skips tasks a vendor installed (Author is a company name, not empty or an account).
/// </summary>
internal static class SchedulerCom
{
    const BindingFlags Get = BindingFlags.GetProperty, Set = BindingFlags.SetProperty, Call = BindingFlags.InvokeMethod;

    static object? Com(object o, string name, BindingFlags how, params object?[] args)
    {
        try { return o.GetType().InvokeMember(name, how, null, o, args); }
        catch (TargetInvocationException ex) when (ex.InnerException is not null) { throw ex.InnerException; }
    }

    static T Root<T>(Func<object, T> use)
    {
        var svc = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
        try
        {
            Com(svc, "Connect", Call);
            return use(Com(svc, "GetFolder", Call, "\\")!);
        }
        finally { Marshal.FinalReleaseComObject(svc); }
    }

    public static List<SchedTask> List() => Root(folder =>
    {
        var list = new List<SchedTask>();
        foreach (var t in (IEnumerable)Com(folder, "GetTasks", Call, 0)!)
        {
            var name = Com(t, "Name", Get) as string ?? "";
            try
            {
                var def = Com(t, "Definition", Get)!;
                var author = Com(Com(def, "RegistrationInfo", Get)!, "Author", Get) as string ?? "";
                if (author.Length > 0 && !author.Contains('\\')) continue;
                list.Add(new SchedTask(name, (bool)Com(t, "Enabled", Get)!, Convert.ToInt32(Com(t, "State", Get)) == 4, Schedule(def),
                    Time(Com(t, "NextRunTime", Get)), Time(Com(t, "LastRunTime", Get)), Convert.ToInt32(Com(t, "LastTaskResult", Get))));
            }
            catch (Exception ex) { Log.Warn($"Reading scheduled task '{name}' failed", ex); }
        }
        list.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        return list;
    });

    public static void SetEnabled(string name, bool on) => Root(f => Com(Com(f, "GetTask", Call, name)!, "Enabled", Set, on));
    public static void Delete(string name) => Root(f => Com(f, "DeleteTask", Call, name, 0));

    /// <summary>"Never" comes back as 1899-12-30.</summary>
    static DateTime? Time(object? v) => v is DateTime d && d.Year > 2000 ? d : null;

    static string Schedule(object def)
    {
        foreach (var trigger in (IEnumerable)Com(def, "Triggers", Get)!)
        {
            if (Com(Com(trigger, "Repetition", Get)!, "Interval", Get) is string { Length: > 0 } iso)
            {
                var every = XmlConvert.ToTimeSpan(iso);
                return every.TotalMinutes < 60 ? $"Every {every.TotalMinutes:0} min" : every.TotalHours < 24 ? $"Every {every.TotalHours:0.#} h" : $"Every {every.TotalDays:0.#} d";
            }
            return Convert.ToInt32(Com(trigger, "Type", Get)) switch
            {
                1 => "Once", 2 => "Daily", 3 => "Weekly", 4 or 5 => "Monthly", 6 => "When idle", 8 => "At startup", 9 => "At sign-in", _ => "On an event",
            };
        }
        return "No trigger";
    }
}
