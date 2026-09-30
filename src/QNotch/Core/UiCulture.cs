using System.Globalization;

namespace QNotch.Core;

/// <summary>The UI text is English, so day and month names are too: dates must not come out in the OS language.</summary>
public static class UiCulture
{
    public static readonly CultureInfo Value = CultureInfo.GetCultureInfo("en-US");
}
