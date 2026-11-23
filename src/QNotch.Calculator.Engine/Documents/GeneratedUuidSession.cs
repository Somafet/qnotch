using Calc.Core;

namespace Calc.Documents;

/// <summary>Version 1 holds UUIDs only. Version 2 adds dice rolls, so binaries that predate dice refuse instead of dropping them.</summary>
public sealed record GeneratedUuidState(int Version, Guid[] Statements, UuidBinding[] Bindings)
{
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public DiceBinding[]? Dice { get; init; }
}

/// <summary>Document identity edits are paired with text edits by the host undo stack. No timer or provider.</summary>
public sealed class GeneratedUuidSession
{
    internal sealed class StatementState(Guid initialId = default)
    {
        private Guid id = initialId;
        private Dictionary<string,Guid>? values;
        private static readonly IReadOnlyDictionary<string,Guid> Empty = new Dictionary<string,Guid>();
        internal Guid Id => id == Guid.Empty ? id = Guid.NewGuid() : id;
        internal IReadOnlyDictionary<string,Guid> Values => values ?? Empty;
        internal void Add(string site, Guid value) => (values ??= new(StringComparer.Ordinal)).Add(site,value);
        /// <summary>The statement's current roll. Rolling replaces it in place; rolls are not undo steps.</summary>
        internal (string Formula, int[] Faces)? Dice;
        internal bool HasState => Values.Count > 0 || Dice is not null;
    }
    private readonly List<StatementState> statements;
    public string Source { get; private set; }
    public bool Enabled { get; private set; }
    public GeneratedUuidSession(string source, GeneratedUuidState? saved = null)
    {
        Source=source;
        if(saved is not null)Validate(source,saved);
        Enabled=saved is not null;
        statements=Rows(source,saved);
    }
    private static List<StatementState> Rows(string source,GeneratedUuidState? saved)
    {
        if(saved is null)return Enumerable.Range(0,Count(source)).Select(_=>new StatementState()).ToList();
        var rows=saved.Statements.Select(id=>new StatementState(id)).ToList();
        var byId=rows.ToDictionary(row=>row.Id);
        foreach(var value in saved.Bindings)byId[value.Statement].Add(value.Site,value.Value);
        foreach(var roll in Current(saved.Dice))byId[roll.Statement].Dice=(roll.Formula,roll.Faces.ToArray());
        return rows;
    }
    private static int Count(string source)=>Math.Min(new SourceLineMap(source).Count,SheetEvaluator.MaxLines);
    public static void Validate(string source,GeneratedUuidState state)
    {
        if(state.Version is not (1 or 2))throw new UnsupportedDocumentVersionException();
        if(state.Statements is null||state.Bindings is null||state.Statements.Length!=Count(source)||(state.Version==2)!=(state.Dice is {Length:>0}))throw new InvalidDataException("Invalid generated UUID state; original preserved");
        if(state.Dice is not null&&state.Dice.Any(roll=>roll is null||roll.Formula is null||roll.Faces is null))throw new InvalidDataException("Invalid dice rolls; original preserved");
        try{_=new StableUuidContext(state.Statements,state.Bindings,Current(state.Dice));}catch(ArgumentException e){throw new InvalidDataException(e.Message,e);}
    }
    /// <summary>Rolls that still belong to their formula. A roll saved under an earlier meaning of its notation (before 18 November 2026,
    /// `crit` was the crunchy critical with half the dice) no longer fits; it is dropped and the line waits for Enter, never misread.</summary>
    private static DiceBinding[] Current(DiceBinding[]? rolls)
    {
        if(rolls is null)return [];
        return rolls.Where(roll=>DiceSyntax.TryParse(roll.Formula) is { } formula&&formula.Notation==roll.Formula&&formula.Fits(roll.Faces)).ToArray();
    }
    public bool Enable(){if(Enabled)return false;Enabled=true;return true;}
    private UuidBinding[] Bindings()=>statements.SelectMany(row=>row.Values.Select(v=>new UuidBinding(row.Id,v.Key,v.Value))).ToArray();
    private DiceBinding[] Rolls()=>statements.Where(row=>row.Dice is not null).Select(row=>new DiceBinding(row.Id,row.Dice!.Value.Formula,row.Dice.Value.Faces.ToArray())).ToArray();
    public StableUuidContext? Context=>!Enabled?null:new(statements.Select(row=>row.Id),Bindings(),Rolls());
    public GeneratedUuidState? Snapshot
    {
        get
        {
            if(!Enabled)return null;
            var rolls=Rolls();
            return new(rolls.Length>0?2:1,statements.Select(row=>row.Id).ToArray(),Bindings()){Dice=rolls.Length>0?rolls:null};
        }
    }
    public bool HasDice=>statements.Any(row=>row.Dice is not null);
    /// <summary>The roll currently held by a line, if any.</summary>
    public DiceBinding? Rolled(int line)=>line>=0&&line<statements.Count&&statements[line].Dice is { } roll?new(statements[line].Id,roll.Formula,roll.Faces.ToArray()):null;
    /// <summary>Rolls a dice line with the OS's cryptographic generator. Without <paramref name="again"/>, a line that already
    /// holds a roll of its current formula keeps it. Returns the new roll, or null when nothing was rolled.</summary>
    public DiceBinding? Roll(int line,bool again)=>Roll(line,again,DiceSyntax.Formulas(Source));
    /// <summary>Rolls every unrolled dice line, for one-shot evaluation (CLI and MCP).</summary>
    public int RollAll()
    {
        var formulas=DiceSyntax.Formulas(Source);var rolled=0;
        foreach(var line in formulas.Keys.Order())if(Roll(line,false,formulas) is not null)rolled++;
        return rolled;
    }
    /// <summary>Copies another session's rolls for the same leading lines, e.g. a sheet with an appended total.</summary>
    public void AdoptRolls(GeneratedUuidSession other)
    {
        var formulas=DiceSyntax.Formulas(Source);
        for(var i=0;i<statements.Count&&i<other.statements.Count;i++)
            if(other.statements[i].Dice is { } roll&&formulas.TryGetValue(i,out var formula)&&formula.Notation==roll.Formula){statements[i].Dice=(roll.Formula,roll.Faces.ToArray());Enabled=true;}
    }
    private DiceBinding? Roll(int line,bool again,IReadOnlyDictionary<int,DiceFormula> formulas)
    {
        if(line<0||line>=statements.Count||!formulas.TryGetValue(line,out var formula))return null;
        var row=statements[line];
        if(!again&&row.Dice is { } held&&held.Formula==formula.Notation&&formula.Fits(held.Faces))return null;
        var others=statements.Where(r=>!ReferenceEquals(r,row)&&r.Dice is not null).ToArray();
        if(others.Length>=StableUuidContext.MaxDiceBindings||others.Sum(r=>r.Dice!.Value.Faces.Length)+formula.Sides.Count>StableUuidContext.MaxDiceFaces)
            throw new ArithmeticException("Dice roll limit exceeded");
        var faces=formula.Sides.Select(sides=>System.Security.Cryptography.RandomNumberGenerator.GetInt32(1,sides+1)).ToArray();
        row.Dice=(formula.Notation,faces);Enabled=true;
        return new(row.Id,formula.Notation,faces.ToArray());
    }
    public void Supply(IReadOnlyList<UuidRequest> requests,StableUuidContext observed)
    {
        if(!Enabled)throw new InvalidOperationException("UUID generation is not enabled");
        var additions=requests.Distinct().Where(r=>r.Line>=0&&r.Line<statements.Count&&StableUuidContext.ValidSite(r.Site)&&!statements[r.Line].Values.ContainsKey(r.Site)).ToArray();
        if(requests.Any(r=>r.Line<0||r.Line>=statements.Count||!StableUuidContext.ValidSite(r.Site)||observed.Statement(r.Line)!=statements[r.Line].Id))throw new InvalidOperationException("Stale UUID generation requests");
        var existing=Bindings();
        if(existing.Length+additions.Length>StableUuidContext.MaxBindings||existing.Sum(v=>v.Site.Length)+additions.Sum(v=>v.Site.Length)>StableUuidContext.MaxSiteCharacters)throw new ArithmeticException("UUID binding limit exceeded");
        foreach(var request in additions)statements[request.Line].Add(request.Site,Guid.NewGuid());
    }
    public void ReplaySource(string source)=>Source=source;
    /// <summary>Adopts a restored document's exact identities. The returned edit joins the source replacement's undo group.</summary>
    public GeneratedUuidEdit Restore(string source,GeneratedUuidState? saved)
    {
        if(saved is not null)Validate(source,saved);
        var rows=Rows(source,saved);
        var edit=new GeneratedUuidEdit(this,0,statements.ToArray(),rows.ToArray(),Enabled,saved is not null);
        statements.Clear();statements.AddRange(rows);Source=source;Enabled=saved is not null;return edit;
    }
    public GeneratedUuidEdit Apply(string source, int? offset = null, int removalLength = 0, int insertionLength = 0)
    {
        if (source.Length > SheetStore.MaxCharacters) throw new ArgumentException("Source exceeds document limit");
        var old = new SourceLineMap(Source); var next = new SourceLineMap(source);
        if (offset is null || offset == 0 && removalLength == Source.Length && insertionLength == source.Length)
        {
            var prefix = 0; while (prefix < Source.Length && prefix < source.Length && Source[prefix] == source[prefix]) prefix++;
            var suffix = 0; while (suffix < Source.Length - prefix && suffix < source.Length - prefix && Source[^(suffix + 1)] == source[^(suffix + 1)]) suffix++;
            offset = prefix; removalLength = Source.Length - prefix - suffix; insertionLength = source.Length - prefix - suffix;
        }
        if (offset < 0 || removalLength < 0 || insertionLength < 0 || offset + removalLength > Source.Length ||
            source.Length != Source.Length - removalLength + insertionLength) throw new ArgumentException("Invalid source identity edit");
        if (!Source.AsSpan(0, offset.Value).SequenceEqual(source.AsSpan(0, offset.Value)) ||
            !Source.AsSpan(offset.Value + removalLength).SequenceEqual(source.AsSpan(offset.Value + insertionLength))) throw new ArgumentException("Source edit does not match its transaction");
        var ids = new StatementState?[Math.Min(next.Count, SheetEvaluator.MaxLines)];
        var delta = insertionLength - removalLength;
        for (var i = 0; i < statements.Count && i < old.Count; i++)
        {
            var start = old.Start(i); var end = old.ContentEnd(i); int target;
            if (start >= offset + removalLength) target = start + delta;
            else if (end <= offset) target = start;
            else if(statements[i].HasState) target=start;
            else continue;
            if (target < 0 || target > source.Length) continue;
            var line = next.LineAt(target);
            if (line >= ids.Length || ids[line] is not null) continue;
            if (next.Start(line) != target && !statements[i].HasState) continue;
            var oldText=Source.AsSpan(start,end-start);var newText=source.AsSpan(next.Start(line),next.ContentEnd(line)-next.Start(line));
            if(!oldText.SequenceEqual(newText))
            {
                if(!statements[i].HasState)continue;
                var identity=UuidSyntax.ExpressionIdentity(oldText.ToString());
                if(identity is null||identity!=UuidSyntax.ExpressionIdentity(newText.ToString()))continue;
            }
            ids[line] = statements[i];
        }
        for (var i = 0; i < ids.Length; i++) if (ids[i] is null) ids[i] = new();
        var first = 0; while (first < statements.Count && first < ids.Length && ReferenceEquals(statements[first],ids[first])) first++;
        var tail = 0; while (tail < statements.Count - first && tail < ids.Length - first && ReferenceEquals(statements[^(tail + 1)],ids[^(tail + 1)])) tail++;
        var edit = new GeneratedUuidEdit(this, first, statements.Skip(first).Take(statements.Count - first - tail).ToArray(), ids.Skip(first).Take(ids.Length - first - tail).Select(id=>id!).ToArray());
        statements.Clear(); statements.AddRange(ids.Select(id=>id!)); Source = source; return edit;
    }
    internal void Patch(int index, StatementState[] expected, StatementState[] replacement, bool? enabled)
    {
        if (index < 0 || index + expected.Length > statements.Count || !statements.Skip(index).Take(expected.Length).SequenceEqual(expected))
            throw new InvalidOperationException("UUID identity undo does not match the source transaction");
        statements.RemoveRange(index, expected.Length); statements.InsertRange(index, replacement); Enabled = enabled ?? Enabled;
    }
}

public sealed class GeneratedUuidEdit
{
    private readonly GeneratedUuidSession session;
    private readonly int index;
    private readonly GeneratedUuidSession.StatementState[] before,after;
    private readonly bool? enabledBefore,enabledAfter;
    internal GeneratedUuidEdit(GeneratedUuidSession session,int index,GeneratedUuidSession.StatementState[] before,GeneratedUuidSession.StatementState[] after,bool? enabledBefore=null,bool? enabledAfter=null)
    {this.session=session;this.index=index;this.before=before;this.after=after;this.enabledBefore=enabledBefore;this.enabledAfter=enabledAfter;}
    public void Undo()=>session.Patch(index,after,before,enabledBefore);
    public void Redo()=>session.Patch(index,before,after,enabledAfter);
}
