using System.Security.Cryptography;
using System.Text;
using Calc.Core;

namespace Calc.Documents;

public sealed record FunctionCatalog(int Version, FunctionDefinition[] Definitions);
public sealed record FunctionReceiptDocument(int Version, Guid SheetId, FunctionReceipt[] Receipts);
public sealed record FunctionSaveTransaction(int Version, SheetDocument Sheet, FunctionCatalog Functions, FunctionReceiptDocument Receipts);

public sealed partial class WorkspaceStore
{
    private FunctionLibrary? functionLibraryCache;
    private int functionCatalogVersion = 1;
    public bool FunctionsRecovered { get; private set; }
    private string FunctionsPath => Path.Combine(directory, "functions.json");
    private string FunctionJournalPath => Path.Combine(directory, "function-save.json");
    private string ReceiptPath(Guid id) => Path.Combine(sheetsDirectory, id.ToString("N") + ".receipts");

    public FunctionLibrary LoadFunctions()
    {
        RequireWorkspace();
        if (functionLibraryCache is not null) return functionLibraryCache;
        if (!File.Exists(FunctionsPath) && !File.Exists(FunctionsPath + ".bak")) return functionLibraryCache = FunctionLibrary.Empty;
        var loaded = AtomicJson.Load<FunctionCatalog>(FunctionsPath, 500_000, ValidateFunctions);
        var library = new FunctionLibrary(loaded.Value.Definitions);
        functionCatalogVersion = loaded.Value.Version;
        // Upgrade a development/legacy catalog before a later older reader can treat new syntax as corruption.
        if (functionCatalogVersion < library.MinimumCatalogVersion)
        { AtomicJson.Write(FunctionsPath, loaded.Value with { Version = library.MinimumCatalogVersion }); functionCatalogVersion = library.MinimumCatalogVersion; }
        FunctionsRecovered = loaded.Recovered;
        return functionLibraryCache = library;
    }
    public IReadOnlyList<FunctionReceipt> LoadFunctionReceipts(Guid id)
    {
        RequireSheet(id);
        return Array.AsReadOnly(ReadFunctionReceiptFile(id).Document.Receipts);
    }
    private (FunctionReceiptDocument Document, bool Recovered) ReadFunctionReceiptFile(Guid id)
    {
        var path = ReceiptPath(id);
        if (!File.Exists(path) && !File.Exists(path + ".bak")) return (new(1, id, []), false);
        var loaded = AtomicJson.Load<FunctionReceiptDocument>(path, 64_000, value => ValidateReceipts(value, id));
        return (loaded.Value, loaded.Recovered);
    }
    public void SaveWithFunctions(SheetDocument sheet, FunctionUpdate update)
    {
        RequireSheet(sheet.Id);
        if (!loadedSheets.Contains(sheet.Id)) throw new InvalidOperationException("Open must succeed before saving a sheet");
        if (update.SourceHash != Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sheet.Source))) || update.BaseFingerprint != LoadFunctions().Fingerprint)
            throw new InvalidDataException("Stale function update; recalculate before saving");
        var transaction = new FunctionSaveTransaction(1, sheet, new(Math.Max(update.Library.MinimumCatalogVersion,functionCatalogVersion), update.Library.Definitions.ToArray()), new(1, sheet.Id, update.Receipts.ToArray()));
        ValidateTransaction(transaction, RequireWorkspace());
        // A durable journal commits intent for all three files. Replay completes interrupted saves
        // before any subsequent workspace operation. Evaluation itself never writes this journal.
        AtomicJson.Write(FunctionJournalPath, transaction);
        RecoverFunctionSave(workspace!);
    }
    private void RecoverFunctionSave(WorkspaceDocument current)
    {
        if (!File.Exists(FunctionJournalPath)) return;
        var transaction = AtomicJson.Read<FunctionSaveTransaction>(FunctionJournalPath, 4_000_000, t => ValidateTransaction(t, current));
        AtomicJson.Write(SheetPath(transaction.Sheet.Id), transaction.Sheet);
        AtomicJson.Write(FunctionsPath, transaction.Functions);
        AtomicJson.Write(ReceiptPath(transaction.Sheet.Id), transaction.Receipts);
        File.Delete(FunctionJournalPath);
        functionLibraryCache = new FunctionLibrary(transaction.Functions.Definitions); functionCatalogVersion = transaction.Functions.Version;
    }
    private static void ValidateFunctions(FunctionCatalog catalog)
    {
        if (catalog.Version < 1 || catalog.Version > FunctionLibrary.LatestCatalogVersion) throw new UnsupportedDocumentVersionException();
        if (catalog.Definitions is null) throw new InvalidDataException("Missing function definitions");
        try { _ = new FunctionLibrary(catalog.Definitions); }
        catch (Exception e) when (e is FormatException or ArithmeticException) { throw new InvalidDataException(e.Message, e); }
    }
    private static void ValidateReceipts(FunctionReceiptDocument receipts, Guid id)
    {
        if (receipts.Version != 1) throw new UnsupportedDocumentVersionException();
        if (receipts.SheetId != id) throw new InvalidDataException("Function receipt sheet identity mismatch");
        try { FunctionUpdate.ValidateReceipts(receipts.Receipts); }
        catch (FormatException e) { throw new InvalidDataException(e.Message, e); }
    }
    private static void ValidateTransaction(FunctionSaveTransaction transaction, WorkspaceDocument current)
    {
        if (transaction.Version != 1) throw new UnsupportedDocumentVersionException();
        if (transaction.Sheet is null || transaction.Functions is null || transaction.Receipts is null || !current.Sheets.Any(s => s.Id == transaction.Sheet.Id))
            throw new InvalidDataException("Invalid function transaction identity");
        SheetStore.Validate(transaction.Sheet); ValidateFunctions(transaction.Functions); ValidateReceipts(transaction.Receipts, transaction.Sheet.Id);
    }
}
