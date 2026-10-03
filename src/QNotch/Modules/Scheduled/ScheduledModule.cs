namespace QNotch.Modules.Scheduled;

/// <summary>What the views show. UI thread only; raises <see cref="Changed"/> only when something differs.</summary>
internal sealed class ScheduledState
{
    public IReadOnlyList<SchedTask> Items { get; private set; } = [];
    public string Error { get; private set; } = "";
    /// <summary>False until the first read finished, so the views do not flash "no tasks".</summary>
    public bool Loaded { get; private set; }
    /// <summary>The Task Scheduler could not be read at all.</summary>
    public bool Unavailable { get; private set; }
    public event Action? Changed;

    public void Set(IReadOnlyList<SchedTask>? items, string error)
    {
        var unavailable = items is null;
        items ??= Items;
        if (Loaded && Unavailable == unavailable && Error == error && Items.SequenceEqual(items)) return;
        (Items, Error, Unavailable, Loaded) = (items, error, unavailable, true);
        Changed?.Invoke();
    }
}

/// <summary>
/// The user's Windows scheduled tasks (Task Scheduler root folder: scripts, agents on a timer) with pause, resume and delete.
/// No timer and no polling: the list is read when the panel opens and after each action.
/// </summary>
public sealed class ScheduledModule : INotchModule, ICadenceAware
{
    internal const string TabId = "scheduled", Icon = "";

    readonly ScheduledState _st = new();
    ModuleContext _ctx = null!;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Tabs.Register(new TabDescriptor(TabId, "Scheduled", Icon, 60, () => new ScheduledTab(this, _st), () => _st.Loaded && !_st.Unavailable && _st.Items.Count == 0));
        ctx.Cards.Register(new CardDescriptor("scheduled", "Scheduled tasks", 90, () => new ScheduledCard(_st, ctx.Shell)));
        ctx.Search.Register(new SearchSource("scheduled", "Scheduled tasks", Icon, 50, q => _st.Items
            .Where(t => t.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(t => new SearchHit(t.Name, t.Meta, () => ctx.Shell.SelectTab(TabId)))));
        if (ctx.Settings.ReadOnly) Seed();
    }

    public void SetCadence(Cadence cadence) { if (cadence == Cadence.Fast) Run(null); }

    internal void SetEnabled(SchedTask t, bool on) => Run(() => SchedulerCom.SetEnabled(t.Name, on));
    internal void Delete(SchedTask t) => Run(() => SchedulerCom.Delete(t.Name));

    /// <summary>Runs <paramref name="action"/> (if any) and re-reads the list, all on the thread pool.</summary>
    void Run(Action? action)
    {
        if (_ctx.Settings.ReadOnly) return;
        Task.Run(() =>
        {
            var error = "";
            List<SchedTask>? items = null;
            try { action?.Invoke(); }
            catch (UnauthorizedAccessException) { error = "Access denied: this task can only be changed by an administrator."; }
            catch (Exception ex) { error = ex.Message.Trim(); }
            try { items = SchedulerCom.List(); }
            catch (Exception ex) { error = ex.Message.Trim(); }
            _ctx.Bus.Run(() => _st.Set(items, error));
        });
    }

    void Seed()
    {
        var at = DateTime.Today.AddHours(9);
        _st.Set(
        [
            new("Nightly backup", false, false, "Daily", null, at.AddHours(-7), 0),
            new("PR review check", true, false, "Every 10 min", at.AddMinutes(50), at.AddMinutes(40), 0),
            new("Sync dotfiles", true, false, "Every 1 h", at.AddMinutes(60), at, 1),
        ], "");
    }
}
