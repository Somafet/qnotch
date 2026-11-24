using Calc.Documents;
namespace Calc.Documents.Tests;
public sealed class StoreTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-tests", Guid.NewGuid().ToString("N"));
    [Fact]
    public void SavesSourceAndIdentityAcrossRestart()
    {
        SheetDocument doc;
        using (var store = new SheetStore(directory))
        {
            doc = store.Load().Document with { Source = "α = 120\nα * 15%", Dark = true };
            store.Save(doc);
        }
        using var reopened = new SheetStore(directory);
        Assert.Equal(doc, reopened.Load().Document);
    }
    [Fact]
    public void CorruptPrimaryRecoversLastGoodAndPreservesRejectedFile()
    {
        using var store = new SheetStore(directory);
        var original = store.Load().Document;
        store.Save(original); store.Save(original with { Source = "new" });
        File.WriteAllText(Path.Combine(directory, "sheet.json"), "{bad");
        var loaded = store.Load();
        Assert.True(loaded.Recovered); Assert.Equal(original, loaded.Document);
        Assert.Single(Directory.GetFiles(directory, "*.corrupt-*"));
        store.Save(loaded.Document);
    }
    [Fact]
    public void InvalidPrimaryWithoutBackupIsNeverOverwritten()
    {
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "sheet.json"); File.WriteAllText(file, "{bad");
        using var store = new SheetStore(directory);
        Assert.ThrowsAny<IOException>(() => store.Load());
        Assert.Throws<InvalidOperationException>(() => store.Save(new(1, Guid.NewGuid(), "", false)));
        Assert.Equal("{bad", File.ReadAllText(file));
    }
    [Fact]
    public void FutureSchemaIsNotReplacedWithOlderBackup()
    {
        using var store = new SheetStore(directory);
        var doc = store.Load().Document; store.Save(doc); store.Save(doc);
        var file = Path.Combine(directory, "sheet.json");
        var future = File.ReadAllText(file).Replace("\"Version\":1", "\"Version\":3");
        File.WriteAllText(file, future);
        Assert.Throws<UnsupportedDocumentVersionException>(() => store.Load());
        Assert.Throws<InvalidOperationException>(() => store.Save(doc));
        Assert.Equal(future, File.ReadAllText(file));
    }
    [Fact]
    public void FailedReplacementPreservesPrimary()
    {
        using var store = new SheetStore(directory);
        var original = store.Load().Document; store.Save(original);
        var file = Path.Combine(directory, "sheet.json");
        using (var locked = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.ThrowsAny<IOException>(() => store.Save(original with { Source = "replacement" }));
        Assert.Equal(original, store.Load().Document);
        Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
    }
    [Fact]
    public void SecondWriterIsRejected()
    {
        using var store = new SheetStore(directory);
        Assert.Throws<IOException>(() => new SheetStore(directory));
    }
    public void Dispose() => Directory.Delete(directory, true);
}
