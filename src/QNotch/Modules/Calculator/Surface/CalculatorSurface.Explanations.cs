using System.Text;
using System.Windows;
using System.Windows.Controls;
using Calc.Core;

namespace Calc.Windows;

public partial class CalculatorSurface
{
    // Hover answers "where did this come from?". The complete trace stays behind Explain (F1).
    private static string Summary(LineResult answer)
    {
        var (note, sources) = SummaryParts(answer);
        return note.Length > 0 && sources.Length > 0 ? note + "\n" + sources : note + sources;
    }
    private static (string Note, string Sources) SummaryParts(LineResult answer)
    {
        // "Exact ..." and "Explicit ..." describe the engine's guarantees, not this value's origin.
        var assumption = answer.Explanation.LastOrDefault(step => step.Assumption is { } text && step.Operation != "reference" &&
            !text.StartsWith("Exact ", StringComparison.Ordinal) && !text.StartsWith("Explicit ", StringComparison.Ordinal))?.Assumption;
        var note = assumption is null ? "" : string.Join(", ", assumption.Split("; ").Take(2));
        var sources = answer.Dependencies.Count > 0 ? T.Format("uses", string.Join(", ", answer.Dependencies.Take(16).Select(n => $"L{n + 1}"))) : "";
        if (answer.Explanation.LastOrDefault(step => step.Payroll is not null)?.Payroll is { } payroll && PayrollBreakdownText.Summary(payroll) is { } split)
            note = split;
        if (answer.Value is { Kind: SheetValueKind.Text } copiedText && copiedText.Text.CopiesExpression)
            note = "Contains NUL; copies an escaped text expression";
        if (answer.Value is { Kind: SheetValueKind.Network } network)
        {
            var value = network.Network;
            note = value.Subnet is { } subnet ? (value.Form == NetworkForm.Membership ? value.Candidate!.Text + " in " + subnet.Cidr + "\n" : "Range: " + subnet.Range + "\n") + subnet.Summary : value.Form == NetworkForm.Address ? "" : value.Details;
        }
        if (answer.Value is { Kind: SheetValueKind.Integer } integer)
        {
            var word = integer.Integer;
            var profile = word.Width is { } width ? $"{width}-bit {(word.Signed ? "signed" : "unsigned")}; base {word.Radix}" : $"Exact integer; base {word.Radix}";
            note = note.Length > 0 ? profile + "\n" + note : profile;
        }
        if (answer.Value is { Kind: SheetValueKind.UptimeBudget } uptime)
            note = (uptime.UptimeBudget.DefaultInterval ? "Mean month: 30.4375 elapsed days" : "Explicit elapsed reporting interval") + "\nPreview rounded to seconds; exact budget retained";
        if (answer.Value is { Kind: SheetValueKind.UsageCount }) note = "Estimated usage; no tokenizer or requests run";
        if (answer.Value is { Kind: SheetValueKind.UsagePrice }) note = "Supplied flat unit price; excludes billing tiers and tax";
        if (answer.Value is { Kind: SheetValueKind.Text } uuid && Guid.TryParseExact(uuid.Text.Value, "D", out _)) note = uuid.Text.Value + "\nCopies complete UUID";
        if (answer.Value is { Kind: SheetValueKind.Colour } colour) note = colour.Colour.HexQuantized ? "Hex uses nearest bytes; copies exact channel expression" : "sRGB; copies exact colour expression";
        if (answer.Value is { Kind: SheetValueKind.Permission } permission) note = "0o" + permission.Permission.Octal + "; copies mode expression";
        if (answer.Value is { Kind: SheetValueKind.Aspect }) note = "Exact width:height; copies ratio expression";
        if (answer.Value is { Kind: SheetValueKind.Unicode } unicode) note = unicode.Unicode.Scalars.Count + " Unicode scalar(s); copies scalar expression";
        if (answer.Value is { Kind: SheetValueKind.Equation } equation) note = equation.Equation.Summary;
        if (answer.Value is { Kind: SheetValueKind.Plot } plot) note = plot.Plot.Summary;
        if (answer.Value is { Kind: SheetValueKind.Chart } chart) note = chart.Chart.Summary;
        if (answer.Value is { Kind: SheetValueKind.Table } table) note = table.Table.Summary;
        return (note, sources);
    }
    private static string Explain(LineResult answer)
    {
        var text = new StringBuilder();
        foreach (var step in answer.Explanation)
        {
            var operands = string.Join(", ", step.Operands);
            text.Append(step.Operation).Append('(').Append(operands).Append(") = ").AppendLine(step.Result);
            if (step.Payroll is { } payroll)
                foreach (var line in PayrollBreakdownText.Lines(payroll)) text.AppendLine(line);
            if (step.Assumption is not null) text.AppendLine(step.Assumption);
            if (step.TextTransform is { } transform)
            {
                text.Append("UTF-8 input: ").Append(transform.InputUtf8Bytes).Append(" bytes; output: ").Append(transform.OutputUtf8Bytes).AppendLine(" bytes");
                text.Append("Input preview: ").AppendLine(transform.InputPreview);
                text.Append("Input byte prefix (hex): ").AppendLine(transform.InputBytePreview);
            }
            if (step.Chemistry is { } chemistry)
            {
                text.Append("Formula ").Append(chemistry.Formula).Append(": ").Append(chemistry.NominalGramsPerMole).AppendLine(" g/mol nominal");
                foreach (var element in chemistry.Composition)
                    text.Append(element.Symbol).Append(" × ").Append(element.Atoms).Append(": ").Append(element.AtomicWeight)
                        .Append(" ± ").Append(element.QuotedUncertainty).Append(" quoted atomic weight; contribution ").Append(element.GramsPerMole).AppendLine(" g/mol");
                text.AppendLine(chemistry.Source);
            }
            if (step.Schedule is { } schedule)
                foreach (var year in schedule)
                    text.Append("Year ").Append(year.Year).Append(" (").Append(year.Payments).Append(" payments): interest ").Append(year.Interest.Display)
                        .Append(", principal ").Append(year.Principal.Display).Append(", balance ").AppendLine(year.Balance.Display);
        }
        if (answer.Value is { Kind: SheetValueKind.Integer } integer)
        {
            var word = integer.Integer;
            text.AppendLine(word.Width is { } width ? $"{width}-bit {(word.Signed ? "signed" : "unsigned")}; base {word.Radix}" : $"Exact integer; base {word.Radix}");
            text.Append("Decimal value: ").AppendLine(word.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
            text.Append("Full representation: ").AppendLine(word.FullText);
            text.Append("Reusable expression: ").AppendLine(word.CopyText);
        }
        if (answer.Value is { Kind: SheetValueKind.Text } textValue)
        {
            text.Append("Complete text expression: ").AppendLine(textValue.Text.ExpressionText);
            if (textValue.Text.CopiesExpression) text.AppendLine("Contains NUL; clipboard uses the escaped expression to retain all text");
        }
        if (answer.Value is { Kind: SheetValueKind.UsageCount } count) AppendDetail(count.UsageCount.Details);
        if (answer.Value is { Kind: SheetValueKind.UsagePrice } price) AppendDetail(price.UsagePrice.Details);
        if (answer.Value is { Kind: SheetValueKind.UptimeBudget } uptime) AppendDetail(uptime.UptimeBudget.Details);
        if (answer.Value is { Kind: SheetValueKind.Network } network) text.AppendLine(network.Network.Details);
        if (answer.Value is { Kind: SheetValueKind.Colour } colour) text.AppendLine(colour.Colour.Details);
        if (answer.Value is { Kind: SheetValueKind.Permission } permission) text.AppendLine(permission.Permission.Details);
        if (answer.Value is { Kind: SheetValueKind.Aspect } aspect) text.AppendLine(aspect.Aspect.Details);
        if (answer.Value is { Kind: SheetValueKind.Unicode } unicode) text.AppendLine(unicode.Unicode.Details);
        if (answer.Value is { Kind: SheetValueKind.Equation } equation) text.AppendLine(equation.Equation.Details);
        if (answer.Value is { Kind: SheetValueKind.Plot } plot) text.AppendLine(plot.Plot.Details);
        if (answer.Value is { Kind: SheetValueKind.Chart } chart) text.AppendLine(chart.Chart.Details);
        if (answer.Value is { Kind: SheetValueKind.Table } table) text.AppendLine(table.Table.Details);
        void AppendDetail(string detail)
        { if (!answer.Explanation.Any(step=>step.Assumption?.Contains(detail,StringComparison.Ordinal)==true)) text.AppendLine(detail); }
        if (answer.Dependencies.Count > 0) text.AppendLine(T.Format("uses", string.Join(", ", answer.Dependencies.Take(16).Select(n => $"L{n + 1}"))));
        return text.ToString().TrimEnd();
    }
    private void ShowExplanation(LineResult answer)
    {
        var body = new TextBox { Text = Explain(answer), IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 12,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent, MaxHeight = 196 };
        System.Windows.Automation.AutomationProperties.SetName(body, T["calculationSteps"]);
        System.Windows.Automation.AutomationProperties.SetAutomationId(body, "calculator-explanation");
        var close = new Button { Content = T["close"] };
        close.Click += (_, _) => CloseOverlay();
        var panel = new StackPanel();
        panel.Children.Add(OverlayTitle(T["explanation"]));
        panel.Children.Add(body);
        panel.Children.Add(OverlayButtons(close));
        ShowOverlay(panel, body, width: 480);
    }
}
