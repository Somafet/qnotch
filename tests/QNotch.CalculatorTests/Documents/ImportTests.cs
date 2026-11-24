using System.Text;
using Calc.Core;
using Calc.Documents;

namespace Calc.Documents.Tests;

public class ImportTests
{
    private static string Fixture(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", "import", name);
    private static string[] Results(string source) => SheetEvaluator.Evaluate(source).Select(r => r.Display).ToArray();

    [Fact]
    public void SoulverJsonIdentifierReferencesBecomeCalcLineReferences()
    {
        var sheet = SheetImport.ReadFile(Fixture("trip.slvr"));
        Assert.Equal(ImportFormat.Soulver, sheet.Format);
        Assert.Equal("trip", sheet.Name);
        // Hand-written oracle: line ids 2 and 3 are referenced by line 4, line 4 by line 5; line numbering is unchanged.
        Assert.Equal("# Trip\nhotel = 3 * 90\ntrain = 45\nL2 + L3\nL4 / 2\n[00000000-0000-4000-8000-000000000000] + 1", sheet.Source);
        var results = Results(sheet.Source);
        Assert.Equal("315", results[3]); Assert.Equal("157.5", results[4]); // 3*90 + 45 = 315; 315/2
        var fileNote = Assert.Single(sheet.Notices, n => n.Line == 0);
        Assert.Contains("answer, appearance, font, theme, version", fileNote.Message);
        Assert.Contains(sheet.Notices, n => n.Line == 6 && n.Message.Contains("matches no line"));
        Assert.DoesNotContain(sheet.Notices, n => n.Line is >= 1 and <= 5);
    }

    [Fact]
    public void SoulverPlainTextLineWordsTranslateOutsideComments()
    {
        var sheet = SheetImport.ReadFile(Fixture("plain-refs.slvr"));
        var lines = sheet.Source.Split('\n');
        Assert.Equal("L3 * 2", lines[3]);
        Assert.Equal("// line9 stays in comments", lines[4]);
        Assert.Equal("line9 + 1", lines[5]);
        Assert.Equal("240", Results(sheet.Source)[3]); // 40 * 3 * 2
        Assert.Contains(sheet.Notices, n => n.Line == 6 && n.Message.Contains("does not name another line"));
    }

    [Fact]
    public void NumiAndTextAreKeptVerbatimWithUnsupportedLinesReported()
    {
        var numi = SheetImport.Parse("budget.numi", Encoding.UTF8.GetBytes("# Monthly budget\r\nrent = 1200\r\nfood = 350\r\nrent + food\r\nprev / 2\r\ntotal\r\n$40 + 5\r\nGroceries\r\n"));
        Assert.Equal(ImportFormat.Numi, numi.Format);
        Assert.Equal("# Monthly budget\nrent = 1200\nfood = 350\nrent + food\nprev / 2\ntotal\n$40 + 5\nGroceries\n", numi.Source);
        var results = Results(numi.Source);
        Assert.Equal("1550", results[3]); Assert.Equal("775", results[4]);
        Assert.Contains(numi.Notices, n => n.Line == 6 && n.Message.StartsWith("No result")); Assert.Contains(numi.Notices, n => n.Line == 7 && n.Message.Contains("cannot evaluate")); Assert.Equal(2, numi.Notices.Count);
        var text = SheetImport.ReadFile(Fixture("notes.txt"));
        Assert.Equal(ImportFormat.Text, text.Format);
        Assert.StartsWith("a = 2\nb = 5\na * b", text.Source);
        Assert.Empty(text.Notices);
        Assert.Equal("10", Results(text.Source)[2]);
        Assert.Equal("budget", SheetImport.ReadFile(Fixture("budget.numi")).Name);
    }

    [Fact]
    public void Utf16AndBomInputsDecode()
    {
        var utf16 = new UnicodeEncoding(false, true).GetPreamble().Concat(Encoding.Unicode.GetBytes("x = 4 €\nx")).ToArray();
        Assert.Equal("x = 4 €\nx", SheetImport.Parse("a.txt", utf16).Source);
        var bom = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("1 + 1")).ToArray();
        Assert.Equal("1 + 1", SheetImport.Parse("a.numi", bom).Source);
    }

    [Theory]
    [InlineData("corrupt.slvr", "Corrupt Soulver file")]
    public void CorruptFixtureIsRejectedAndUnchanged(string name, string message)
    {
        var path = Fixture(name); var before = File.ReadAllBytes(path);
        var error = Assert.Throws<ImportRejectedException>(() => SheetImport.ReadFile(path));
        Assert.Contains(message, error.Message); Assert.Equal(before, File.ReadAllBytes(path));
    }

    [Fact]
    public void HostileOrOversizedInputsAreRejected()
    {
        Assert.Contains("Binary", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.txt", [0x31, 0x00, 0x32])).Message);
        Assert.Contains("UTF-8", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.numi", [0x31, 0xC3, 0x28])).Message);
        Assert.Contains("U+001B", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.txt", Encoding.UTF8.GetBytes("1\n\u001b[2J"))).Message);
        Assert.Contains("bytes", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.txt", new byte[SheetImport.MaxTextBytes + 1])).Message);
        Assert.Contains("characters", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.txt", Encoding.ASCII.GetBytes(new string('1', SheetStore.MaxCharacters + 1)))).Message);
        Assert.Contains("lines", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.txt", Encoding.ASCII.GetBytes(new string('\n', SheetEvaluator.MaxLines)))).Message);
        Assert.Contains("Unsupported file type", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.exe", [0x31])).Message);
        Assert.Contains("Unrecognized", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.slvr", Encoding.UTF8.GetBytes("{\"version\": 3, \"rows\": [1, 2]}"))).Message);
        var deep = new string('[', SheetImport.MaxJsonDepth + 2) + new string(']', SheetImport.MaxJsonDepth + 2);
        Assert.Contains("Corrupt", Assert.Throws<ImportRejectedException>(() => SheetImport.Parse("a.slvr", Encoding.UTF8.GetBytes(deep))).Message);
    }

    [Fact]
    public void LargeFileOnDiskIsRejectedBeforeReading()
    {
        var directory = Directory.CreateTempSubdirectory("calc-import-");
        try
        {
            var path = Path.Combine(directory.FullName, "big.numi");
            using (var stream = File.Create(path)) stream.SetLength(SheetImport.MaxTextBytes + 1);
            Assert.Contains("exceeds", Assert.Throws<ImportRejectedException>(() => SheetImport.ReadFile(path)).Message);
            Assert.Equal(SheetImport.MaxTextBytes + 1, new FileInfo(path).Length);
            Assert.Contains("not found", Assert.Throws<ImportRejectedException>(() => SheetImport.ReadFile(Path.Combine(directory.FullName, "missing.slvr"))).Message);
        }
        finally { directory.Delete(true); }
    }

    [Fact]
    public void SoulverBodyAndEmbeddedLineBreaksKeepNumbering()
    {
        var body = SheetImport.Parse("b.slvr", Encoding.UTF8.GetBytes("{\"text\": \"a = 1\\nb = 2\\nline1 + line2\", \"style\": 1}"));
        Assert.Equal("a = 1\nb = 2\nL1 + L2", body.Source);
        Assert.Equal("3", Results(body.Source)[2]);
        Assert.Contains(body.Notices, n => n.Line == 0 && n.Message.Contains("style"));
        var broken = SheetImport.Parse("c.slvr", Encoding.UTF8.GetBytes("{\"lines\": [{\"text\": \"1 +\\n2\"}, {\"text\": \"line1 * 3\"}]}"));
        Assert.Equal("1 + 2\nL1 * 3", broken.Source);
        Assert.Equal("9", Results(broken.Source)[1]);
        Assert.Contains(broken.Notices, n => n.Line == 1 && n.Message.Contains("joined"));
    }

    [Fact]
    public void ShortAndDuplicateIdentifiersAreNotGuessed()
    {
        var shortIds = SheetImport.Parse("s.slvr", Encoding.UTF8.GetBytes("{\"lines\": [{\"id\": 1, \"text\": \"5\"}, {\"id\": 2, \"text\": \"[1] + 1\"}]}"));
        Assert.Equal("5\n[1] + 1", shortIds.Source);
        var duplicate = SheetImport.Parse("d.slvr", Encoding.UTF8.GetBytes("{\"lines\": [{\"id\": \"abcdefgh\", \"text\": \"5\"}, {\"id\": \"abcdefgh\", \"text\": \"6\"}, {\"id\": \"ijklmnop\", \"text\": \"[abcdefgh] + 1\"}]}"));
        Assert.Equal("5\n6\n[abcdefgh] + 1", duplicate.Source);
        Assert.Contains(duplicate.Notices, n => n.Line == 3 && n.Message.Contains("ambiguous"));
    }

    [Fact]
    public void NamesAreValidAndUnique()
    {
        Assert.Equal("Imported", SheetImport.SheetName("   .txt"));
        Assert.Equal("a b", SheetImport.SheetName("a\tb.numi"));
        Assert.Equal(WorkspaceStore.MaxNameLength, SheetImport.SheetName(new string('x', 200) + ".txt").Length);
        Assert.Equal("Budget 3", SheetImport.UniqueName("Budget", ["budget", "Budget 2"]));
        var longName = new string('y', WorkspaceStore.MaxNameLength);
        Assert.Equal(WorkspaceStore.MaxNameLength, SheetImport.UniqueName(longName, [longName]).Length);
    }

    [Fact]
    public void ImportedSourceCreatesAPersistedSheet()
    {
        var directory = Directory.CreateTempSubdirectory("calc-import-");
        try
        {
            var sheet = SheetImport.ReadFile(Fixture("trip.slvr"));
            using (var store = new WorkspaceStore(directory.FullName))
            {
                var workspace = store.Load().Workspace;
                workspace = store.Create(SheetImport.UniqueName(sheet.Name, workspace.Sheets.Select(s => s.Name)), sheet.Source);
                Assert.Equal(sheet.Source, store.Open(workspace.ActiveSheetId).Document.Source);
            }
            using var reopened = new WorkspaceStore(directory.FullName);
            var loaded = reopened.Load().Workspace;
            Assert.Contains(loaded.Sheets, s => s.Name == "trip");
            Assert.Equal(sheet.Source, reopened.Open(loaded.Sheets.Single(s => s.Name == "trip").Id).Document.Source);
        }
        finally { directory.Delete(true); }
    }
}
