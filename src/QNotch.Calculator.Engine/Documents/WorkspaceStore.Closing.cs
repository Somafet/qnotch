namespace Calc.Documents;

public sealed partial class WorkspaceStore
{
    /// <summary>Deletes a group of sheets in one catalog write: all of them or, if the write fails, none. At least one sheet always remains.</summary>
    public WorkspaceDocument DeleteMany(IReadOnlyCollection<Guid> ids)
    {
        var current = RequireWorkspace();
        var gone = ids.ToHashSet();
        var remaining = current.Sheets.Where(sheet => !gone.Contains(sheet.Id)).ToArray();
        if (remaining.Length == 0) throw new InvalidDataException("Keep at least one sheet");
        if (remaining.Length == current.Sheets.Length) return Copy(current);
        var next = current with { Sheets = remaining, ActiveSheetId = gone.Contains(current.ActiveSheetId) ? remaining[0].Id : current.ActiveSheetId };
        Commit(next);
        loadedSheets.ExceptWith(gone);
        return Copy(next);
    }
}
