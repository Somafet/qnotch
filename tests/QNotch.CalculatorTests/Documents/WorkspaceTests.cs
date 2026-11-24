using System.Text.Json;
using Calc.Documents;

namespace Calc.Documents.Tests;

public sealed class WorkspaceTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    private string Catalog => Path.Combine(directory, "workspace.json");
    private string Body(Guid id) => Path.Combine(directory, "sheets", id.ToString("N") + ".json");
    [Fact]
    public void CreateRenameSwitchDeleteAndRestart()
    {
        Guid first; Guid second;
        using (var store = new WorkspaceStore(directory))
        {
            first = store.Load().Workspace.ActiveSheetId;
            var state = store.Create("Travel", "α = 20\nα*3"); second = state.ActiveSheetId;
            store.Rename(second, "Trips");
            var sheet = store.Open(second).Document;
            store.Save(sheet with { Source = "20*4" });
            store.SetDark(true); store.Select(first);
        }
        using (var store = new WorkspaceStore(directory))
        {
            var state = store.Load().Workspace;
            Assert.True(state.Dark); Assert.Equal(first, state.ActiveSheetId);
            Assert.Equal("Trips", state.Sheets[1].Name);
            Assert.Equal("20*4", store.Open(second).Document.Source);
            state = store.Delete(first);
            Assert.Equal(second, state.ActiveSheetId); Assert.Single(state.Sheets);
            Assert.Throws<InvalidOperationException>(() => store.Delete(second));
        }
        using var reopened = new WorkspaceStore(directory);
        Assert.Equal(second, reopened.Load().Workspace.ActiveSheetId);
    }
    [Fact]
    public void LegacyMigrationPreservesIdentityTextAppearanceAndOriginalBytes()
    {
        SheetDocument original;
        using (var legacy = new SheetStore(directory))
        {
            original = legacy.Load().Document with { Source = "// 😀 日本語\n120*15%", Dark = true };
            legacy.Save(original);
        }
        var bytes = File.ReadAllBytes(Path.Combine(directory, "sheet.json"));
        using (var store = new WorkspaceStore(directory))
        {
            var result = store.Load();
            Assert.True(result.Migrated); Assert.True(result.Workspace.Dark);
            Assert.Equal(original.Id, result.Workspace.ActiveSheetId);
            Assert.Equal(original, store.Open(original.Id).Document);
        }
        Assert.Equal(bytes, File.ReadAllBytes(Path.Combine(directory, "sheet.json")));
        using var reopened = new WorkspaceStore(directory);
        Assert.False(reopened.Load().Migrated);
    }
    [Fact]
    public void MigrationRetriesAfterCatalogCommitFailure()
    {
        using (var legacy = new SheetStore(directory)) legacy.Save(legacy.Load().Document with { Source = "keep" });
        Directory.CreateDirectory(Catalog); // prevents committing catalog after body was written
        using (var store = new WorkspaceStore(directory)) Assert.ThrowsAny<IOException>(() => store.Load());
        Directory.Delete(Catalog);
        using var retry = new WorkspaceStore(directory);
        var loaded = retry.Load();
        Assert.True(loaded.Migrated);
        Assert.Equal("keep", retry.Open(loaded.Workspace.ActiveSheetId).Document.Source);
    }
    [Fact]
    public void LazyCatalogDoesNotOpenUnselectedBodies()
    {
        Guid first; Guid second;
        using (var store = new WorkspaceStore(directory))
        {
            first = store.Load().Workspace.ActiveSheetId;
            second = store.Create("Broken").ActiveSheetId; store.Select(first);
        }
        File.WriteAllText(Body(second), "{bad");
        using var reopened = new WorkspaceStore(directory);
        Assert.Equal(2, reopened.Load().Workspace.Sheets.Length);
        Assert.NotNull(reopened.Open(first).Document);
        Assert.ThrowsAny<IOException>(() => reopened.Open(second));
        Assert.Throws<InvalidOperationException>(() => reopened.Save(new(1, second, "overwrite", false)));
    }
    [Fact]
    public void FailedMetadataChangeKeepsExistingCatalogAndState()
    {
        using var store = new WorkspaceStore(directory);
        var first = store.Load().Workspace.ActiveSheetId;
        using (var locked = new FileStream(Catalog, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            Assert.ThrowsAny<IOException>(() => store.Create("New", "do not claim creation"));
            Assert.Single(Directory.GetFiles(Path.Combine(directory, "sheets"), "*.json"));
            Assert.ThrowsAny<IOException>(() => store.Rename(first, "Not saved"));
        }
        var next = store.Select(first);
        Assert.Single(next.Sheets); Assert.Equal("Sheet", next.Sheets[0].Name);
        Assert.Single(Directory.GetFiles(Path.Combine(directory, "sheets"), "*.json"));
    }
    [Fact]
    public void CatalogRecoveryRetainsBodiesNeededByBackup()
    {
        using var store = new WorkspaceStore(directory);
        var first = store.Load().Workspace.ActiveSheetId;
        var second = store.Create("Second").ActiveSheetId;
        store.Delete(first);
        Assert.True(File.Exists(Body(first)));
        File.WriteAllText(Catalog, "{bad");
        var recovered = store.Load();
        Assert.True(recovered.Recovered); Assert.Equal(2, recovered.Workspace.Sheets.Length);
        Assert.NotNull(store.Open(first).Document); Assert.NotNull(store.Open(second).Document);
    }
    [Fact]
    public void FutureCatalogAndFutureSheetCannotBeOverwritten()
    {
        using var store = new WorkspaceStore(directory);
        var first = store.Load().Workspace.ActiveSheetId;
        store.Open(first);
        var futureBody = File.ReadAllText(Body(first)).Replace("\"Version\":1", "\"Version\":3");
        File.WriteAllText(Body(first), futureBody);
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.Open(first));
        Assert.Throws<InvalidOperationException>(() => store.Save(new(1, first, "overwrite", false)));
        File.WriteAllText(Catalog, File.ReadAllText(Catalog).Replace("\"Version\":1", "\"Version\":2"));
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.Load());
        Assert.Throws<InvalidOperationException>(() => store.Create("no"));
        Assert.Equal(futureBody, File.ReadAllText(Body(first)));
    }
    [Fact]
    public void CatalogValidationAndResultIsolation()
    {
        using var store = new WorkspaceStore(directory);
        var state = store.Load().Workspace;
        var id = state.ActiveSheetId;
        state.Sheets[0] = new(Guid.NewGuid(), "tamper");
        Assert.Equal(id, store.Select(id).Sheets[0].Id);
        Assert.Throws<InvalidDataException>(() => store.Rename(id, " "));
        Assert.Throws<InvalidDataException>(() => store.Rename(id, "bad\nname"));
        Assert.Throws<InvalidDataException>(() => store.Rename(id, new string('x', 81)));
        var invalid = new WorkspaceDocument(1, id, false, [new(id, "one"), new(id, "two")]);
        File.WriteAllText(Catalog, JsonSerializer.Serialize(invalid));
        File.Delete(Catalog + ".bak");
        Assert.ThrowsAny<IOException>(() => store.Load());
    }
    [Fact]
    public void FullUnicodeCatalogRoundtripsAndRejectsOverflow()
    {
        Directory.CreateDirectory(directory);
        var entries = Enumerable.Range(0, WorkspaceStore.MaxSheets).Select(_ => new SheetEntry(Guid.NewGuid(), new string('日', WorkspaceStore.MaxNameLength))).ToArray();
        File.WriteAllText(Catalog, JsonSerializer.Serialize(new WorkspaceDocument(1, entries[0].Id, false, entries)));
        using var store = new WorkspaceStore(directory);
        Assert.Equal(256, store.Load().Workspace.Sheets.Length);
        Assert.Throws<InvalidDataException>(() => store.Create("overflow"));
    }
    [Fact]
    public void CatalogAndLegacyStoreShareExclusiveOwnership()
    {
        using var store = new WorkspaceStore(directory);
        Assert.Throws<IOException>(() => new WorkspaceStore(directory));
        Assert.Throws<IOException>(() => new SheetStore(directory));
    }
    public void Dispose() => Directory.Delete(directory, true);
}
