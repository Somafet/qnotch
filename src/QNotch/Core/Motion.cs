using System.Windows;

namespace QNotch.Core;

/// <summary>Effective "animations allowed" flag: user setting AND OS setting. Check <see cref="Enabled"/> before starting any animation.</summary>
public static class Motion
{
    public static bool Enabled { get; private set; } = true;
    public static event Action? Changed;

    public static void Refresh(bool userReduce)
    {
        var e = !userReduce && SystemParameters.ClientAreaAnimation;
        if (e == Enabled) return;
        Enabled = e;
        Changed?.Invoke();
    }
}
