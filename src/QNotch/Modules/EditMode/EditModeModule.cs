namespace QNotch.Modules.EditMode;

/// <summary>
/// Stub. The Edit mode agent replaces everything in this folder: jiggle, lift on drag, settle on drop.
/// Hooks: IShell.IsEditMode / EditModeChanged, ctx.CardLayout.Hosts (live CardHost list) and CardLayout.Move(id, targetId).
/// CardHost.RenderTransform is free for you to animate. Respect Core.Motion.Enabled.
/// </summary>
public sealed class EditModeModule : INotchModule
{
    public string Id => "editmode";

    public void Initialize(ModuleContext ctx)
    {
    }
}
