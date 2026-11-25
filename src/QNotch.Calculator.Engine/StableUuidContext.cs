using System.Security.Cryptography;
using System.Text;

namespace Calc.Core;

internal sealed record UuidExpression(int Site) : Expression;
public sealed record UuidBinding(Guid Statement, string Site, Guid Value);
public sealed record UuidRequest(int Line, string Site);

/// <summary>Immutable document-owned UUID bindings. Core never obtains entropy or mutates generated state.</summary>
public sealed class StableUuidContext
{
    public const int MaxBindings = 1024;
    public const int MaxSiteCharacters = 64000;
    public const int MaxDiceBindings = 1024;
    public const int MaxDiceFaces = 100_000;
    private readonly Guid[] statements;
    private readonly Dictionary<Guid, DiceBinding> dice = [];
    private readonly Dictionary<Guid, string> diceKeys = [];
    private readonly Dictionary<Guid, Dictionary<string, Guid>> bindings = [];
    private readonly Dictionary<Guid, string> keys = [];
    public StableUuidContext(IEnumerable<Guid> statementIds, IEnumerable<UuidBinding> values, IEnumerable<DiceBinding>? rolls = null)
    {
        statements = statementIds.Take(SheetEvaluator.MaxLines + 1).ToArray();
        var ids=statements.ToHashSet();
        if (statements.Length is < 1 or > SheetEvaluator.MaxLines || ids.Contains(Guid.Empty) || ids.Count != statements.Length)
            throw new ArgumentException("Invalid UUID statement identities");
        var count=0;var characters=0;
        foreach(var binding in values)
        {
            if(binding is null || ++count>MaxBindings || !ids.Contains(binding.Statement) || !ValidSite(binding.Site) || !IsVersion4(binding.Value) || (characters+=binding.Site.Length)>MaxSiteCharacters)
                throw new ArgumentException("Invalid or excessive UUID bindings");
            if(!bindings.TryGetValue(binding.Statement,out var row)) bindings[binding.Statement]=row=new(StringComparer.Ordinal);
            if(!row.TryAdd(binding.Site,binding.Value))throw new ArgumentException("Duplicate UUID binding");
        }
        var faces=0;
        foreach(var roll in rolls??[])
        {
            if(roll is null||dice.Count>=MaxDiceBindings||!ids.Contains(roll.Statement)||roll.Formula is null||roll.Faces is null||(faces+=roll.Faces.Length)>MaxDiceFaces||
               DiceSyntax.TryParse(roll.Formula) is not { } formula||formula.Notation!=roll.Formula||!formula.Fits(roll.Faces)||!dice.TryAdd(roll.Statement,roll))
                throw new ArgumentException("Invalid or excessive dice rolls");
            diceKeys[roll.Statement]=roll.Formula+"="+string.Join(',',roll.Faces);
        }
        foreach(var pair in bindings)
            keys[pair.Key]=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n',pair.Value.OrderBy(v=>v.Key,StringComparer.Ordinal).Select(v=>v.Key+"="+v.Value.ToString("D"))))));
    }
    public static bool IsVersion4(Guid value)
    {var text=value.ToString("N");return text[12]=='4'&&"89ab".Contains(text[16]);}
    public static bool ValidSite(string? site) => site is {Length:>0 and <=8192} && !site.Contains('\0') && !site.Contains('\n') && !site.Contains('\r');
    public Guid Statement(int line) => line>=0&&line<statements.Length?statements[line]:throw new ArgumentOutOfRangeException(nameof(line));
    public bool HasDice => dice.Count > 0;
    internal DiceBinding? Dice(int line) => line>=0&&line<statements.Length?dice.GetValueOrDefault(statements[line]):null;
    internal string? DiceKey(int line) => line>=0&&line<statements.Length?diceKeys.GetValueOrDefault(statements[line]):null;
    internal (Guid Statement, string? Values) Key(int line) => line>=0&&line<statements.Length?(statements[line],keys.GetValueOrDefault(statements[line])):default;
    internal string Resolve(int line,string path,int site,ContextReads reads)
    {
        if(line<0||line>=statements.Length||site<0||path.Length>8190)throw new ArithmeticException("UUID generation scope unavailable");
        var key=path+"/"+site.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if(!ValidSite(key))throw new ArithmeticException("UUID generation scope unavailable");
        if(bindings.TryGetValue(statements[line],out var row)&&row.TryGetValue(key,out var value))return value.ToString("D");
        if(reads.UuidRequests.Count>=MaxBindings)throw new ArithmeticException("UUID generation limit exceeded");
        reads.UuidRequests.Add(new(line,key));
        // Discovery may continue through the expression graph, but pending values/traces are masked before return.
        return "00000000-0000-4000-8000-000000000000";
    }
}

public static class UuidSyntax
{
    /// <summary>Formatting and annotations do not change a generated expression's identity.</summary>
    public static string? ExpressionIdentity(string source)
    {
        try
        {
            var line=SheetSyntax.Scan(source);
            if(line.Error is not null||line.Boundary||line.Directive is not null||line.Text.Length==0)return null;
            // Labels, spacing and case keep a roll; changing the dice clears it.
            if(DiceSyntax.TryParse(line.Text) is { } dice)return "dice:"+dice.Notation;
            return FunctionLibrary.Canonical(new("_",[],line.Text));
        }
        catch(Exception e)when(e is FormatException or ArithmeticException){return null;}
    }
    /// <summary>Recognize actual generation, including transitive calls; comments/text/unused declarations do not activate it.</summary>
    public static bool RequiresState(string source, FunctionLibrary? library = null, CancellationToken token = default)
    {
        library ??= FunctionLibrary.Empty;
        if (!source.Contains("uuid", StringComparison.OrdinalIgnoreCase) && !library.HasUuid) return false;
        if (source.Length > SheetEvaluator.MaxCharacters) throw new ArgumentException("Sheet exceeds document limit");
        var lines = source.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        if (lines.Length > SheetEvaluator.MaxLines) return false;
        var scanned = lines.Select(line => SheetSyntax.Scan(line, token)).ToArray();
        var update = FunctionUpdate.Prepare(source, scanned, library, [], token);
        var names = scanned.Where(line => line.Assignment is not null).Select(line => line.Assignment!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var line in scanned)
        {
            token.ThrowIfCancellationRequested();
            if (line.FunctionName is not null || line.Directive is not null) continue;
            var parsed = SheetSyntax.Parse(line, names, token);
            if (parsed.Error is null && parsed.Expression is { } expression && ExpressionEvaluation.Walk(expression).Any(node =>
                node is UuidExpression || node is CallExpression call && update.Library.UsesUuid(call.Name))) return true;
        }
        return false;
    }
}
