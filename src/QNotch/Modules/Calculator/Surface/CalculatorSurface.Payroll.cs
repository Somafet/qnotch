using System.Globalization;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    private static string? SystemPayrollRegion()
    {
        try { return new RegionInfo(CultureInfo.CurrentCulture.Name).TwoLetterISORegionName; }
        catch(ArgumentException) { return null; }
    }
}
