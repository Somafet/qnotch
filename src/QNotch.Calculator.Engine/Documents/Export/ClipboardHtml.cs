using System.Globalization;
using System.Text;

namespace Calc.Documents.Export;

/// <summary>Windows "HTML Format" clipboard payload. Offsets in the header are UTF-8 byte positions of the document and the fragment,
/// as the format requires; WPF passes the string through unchanged.</summary>
public static class ClipboardHtml
{
    private const string Header = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
    private const string Before = "<html><head><meta charset=\"utf-8\"></head><body><!--StartFragment-->";
    private const string After = "<!--EndFragment--></body></html>";

    public static string Wrap(string fragment)
    {
        var headerLength = Encoding.UTF8.GetByteCount(string.Format(CultureInfo.InvariantCulture, Header, 0, 0, 0, 0));
        var startFragment = headerLength + Encoding.UTF8.GetByteCount(Before);
        var endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
        var endHtml = endFragment + Encoding.UTF8.GetByteCount(After);
        return string.Format(CultureInfo.InvariantCulture, Header, headerLength, endHtml, startFragment, endFragment) + Before + fragment + After;
    }
}
