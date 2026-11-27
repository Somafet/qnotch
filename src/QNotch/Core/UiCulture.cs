using System.Globalization;

namespace QNotch.Core;

/// <summary>Number formatting stays English ("20.8/31.9 GB") whatever the OS or interface language, so parsing and layout never change.
/// Day and month names follow the interface language: use <see cref="Dates"/> for them.</summary>
public static class UiCulture
{
    public static readonly CultureInfo Value = CultureInfo.GetCultureInfo("en-US");

    /// <summary>Culture for date and time text shown to the user, in the interface language (<see cref="L.Culture"/>).</summary>
    public static CultureInfo Dates => L.Culture;
}
