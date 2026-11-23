namespace Calc.Documents;

/// <summary>Narrow store operations used only by <see cref="FolderSync"/>. They keep the catalog-before-body
/// and backup rules of ordinary edits; imported sheets keep the identity they have on every computer.</summary>
public sealed partial class WorkspaceStore
{
    internal string DataDirectory => directory;
    internal WorkspaceDocument CurrentWorkspace => Copy(RequireWorkspace());
    internal (long Ticks, long Length)? SheetStamp(Guid id)
    {
        var info = new FileInfo(SheetPath(id));
        return info.Exists ? (info.LastWriteTimeUtc.Ticks, info.Length) : null;
    }
    internal SheetDocument ReadSheetForSync(Guid id) { RequireSheet(id); return ReadSaved(id); }
    internal static void ValidateSheetName(string name) => ValidateName(name);

    internal WorkspaceDocument ImportSyncedSheet(SheetDocument sheet, string name)
    {
        var current = RequireWorkspace();
        if (current.Sheets.Any(s => s.Id == sheet.Id)) throw new InvalidDataException("Sheet already present");
        if (current.Sheets.Length == MaxSheets) throw new InvalidDataException($"Maximum {MaxSheets} sheets");
        ValidateName(name); SheetStore.Validate(sheet);
        Directory.CreateDirectory(sheetsDirectory);
        AtomicJson.Write(SheetPath(sheet.Id), sheet);
        var next = current with { Sheets = [.. current.Sheets, new(sheet.Id, name)] };
        try { Commit(next); }
        catch
        {
            try { File.Delete(SheetPath(sheet.Id)); File.Delete(SheetPath(sheet.Id) + ".bak"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            throw;
        }
        return Copy(next);
    }

    /// <summary>Replaces a sheet with a newer synchronized revision. The replaced content is first kept in version history.</summary>
    internal WorkspaceDocument ApplySyncedSheet(SheetDocument sheet, string name, DateTimeOffset now)
    {
        RequireSheet(sheet.Id); ValidateName(name); SheetStore.Validate(sheet);
        var added = loadedSheets.Add(sheet.Id);
        try { CaptureVersion(sheet.Id, now, true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidDataException or System.Text.Json.JsonException) { }
        finally { if (added) loadedSheets.Remove(sheet.Id); }
        AtomicJson.Write(SheetPath(sheet.Id), sheet);
        var current = RequireWorkspace();
        if (current.Sheets.Single(s => s.Id == sheet.Id).Name != name)
            Commit(current with { Sheets = current.Sheets.Select(s => s.Id == sheet.Id ? s with { Name = name } : s).ToArray() });
        return Copy(RequireWorkspace());
    }

    internal WorkspaceDocument RemoveSyncedSheet(Guid id) => Delete(id);
}
