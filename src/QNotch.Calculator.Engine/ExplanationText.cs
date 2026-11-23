using System.Text;

namespace Calc.Core;

/// <summary>Plain-text rendering of a result's structured explanation for non-WPF hosts (CLI, MCP).
/// Mirrors the Windows F1 explanation text; it formats the existing result and never computes a separate answer.</summary>
public static class ExplanationText
{
    public static string Render(LineResult answer)
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
        if (answer.Dependencies.Count > 0) text.Append("Uses ").AppendLine(string.Join(", ", answer.Dependencies.Take(16).Select(n => $"L{n + 1}")));
        return text.ToString().TrimEnd();
    }
}
