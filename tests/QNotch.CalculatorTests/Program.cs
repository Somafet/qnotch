using Calc.Documents;
using QNotch.Calculator;

// Calculator tab checks: what closing, undoing and expiring do to the tab list, and that a closed sheet stays in the real store until its
// window ends. No window, no network. The engine's own behaviour is covered by the suites of the app it came from.
var failures = 0;
var checks = 0;
var t0 = new DateTimeOffset(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

static SheetTab[] Sheets(int count) => Enumerable.Range(1, count).Select(i => new SheetTab(new Guid(i, 0, 0, new byte[8]), "Sheet " + i)).ToArray();
static SheetTabList List(int count, int active = 0)
{
    var sheets = Sheets(count);
    var list = new SheetTabList();
    list.Update(sheets, sheets[active].Id);
    return list;
}
static Guid Id(int oneBased) => new(oneBased, 0, 0, new byte[8]);
static string Names(SheetTabList list) => string.Join(",", list.Visible.Select(tab => tab.Name.Replace("Sheet ", "")));

Test("closing an inactive tab leaves the active sheet", () =>
{
    var list = List(4, 1);
    var closed = list.Close(Id(4), t0);
    Assert(closed is { WasActive: false, Position: 3 });
    Assert(list.ActiveId == Id(2));
    Assert(Names(list) == "1,2,3");
});
Test("closing the active tab activates its right neighbor, or the left one at the end", () =>
{
    var list = List(4, 1);
    list.Close(Id(2), t0);
    Assert(list.ActiveId == Id(3));
    var last = List(3, 2);
    last.Close(Id(3), t0);
    Assert(last.ActiveId == Id(2));
});
Test("neighbors go outward, right first", () =>
    Assert(string.Join(",", List(5).NeighborsOf(Id(3)).Select(id => id.ToByteArray()[0])) == "4,2,5,1"));
Test("a chosen neighbor wins over the nearest one", () =>
{
    var list = List(4, 1);
    list.Close(Id(2), t0, Id(1));
    Assert(list.ActiveId == Id(1));
});
Test("the last visible sheet cannot be closed", () =>
{
    var list = List(2);
    Assert(list.Close(Id(2), t0) is not null);
    Assert(list.CanClose(Id(1)) == CloseVerdict.LastSheet);
    Assert(list.Close(Id(1), t0) is null);
    Assert(Names(list) == "1" && list.ActiveId == Id(1));
});
Test("closing all but one quickly stops at one", () =>
{
    var list = List(6, 2);
    foreach (var tab in list.Visible.ToArray()) list.Close(tab.Id, t0);
    Assert(list.Visible.Count == 1 && list.Closed.Count == 5);
    Assert(list.ActiveId == list.Visible[0].Id);
});
Test("an unknown or already closed sheet is refused", () =>
{
    var list = List(3);
    Assert(list.CanClose(Id(9)) == CloseVerdict.Unknown);
    list.Close(Id(3), t0);
    Assert(list.CanClose(Id(3)) == CloseVerdict.Unknown);
    Assert(list.Close(Id(3), t0) is null);
    Assert(!list.SetActive(Id(3)));
});
Test("undo restores the most recent close, at its old place", () =>
{
    var list = List(5);
    list.Close(Id(2), t0);
    list.Close(Id(4), t0);
    Assert(Names(list) == "1,3,5");
    Assert(list.Undo(t0)?.Id == Id(4));
    Assert(Names(list) == "1,3,4,5");
    Assert(list.Undo(t0)?.Id == Id(2));
    Assert(Names(list) == "1,2,3,4,5");
    Assert(list.Undo(t0) is null);
});
Test("undo brings an active sheet back in front, an inactive one stays behind", () =>
{
    var active = List(3, 1);
    active.Close(Id(2), t0);
    active.SetActive(Id(1));   // the user moved on
    active.Undo(t0);
    Assert(active.ActiveId == Id(2));
    var inactive = List(3, 1);
    inactive.Close(Id(3), t0);
    inactive.Undo(t0);
    Assert(inactive.ActiveId == Id(2));
});
Test("every close and undo moves the one deadline on", () =>
{
    var list = List(4);
    list.Close(Id(2), t0);
    Assert(list.DueAt == t0 + SheetTabList.UndoWindow);
    var later = t0.AddSeconds(5);
    list.Close(Id(3), later);
    Assert(list.DueAt == later + SheetTabList.UndoWindow);
    Assert(list.TakeExpired(t0 + SheetTabList.UndoWindow).Count == 0); // the first close did not expire on its own
    var undone = later.AddSeconds(1);
    list.Undo(undone);
    Assert(list.DueAt == undone + SheetTabList.UndoWindow);
    list.Undo(undone);
    Assert(list.DueAt is null);
});
Test("expiry hands over every waiting close, oldest first, once", () =>
{
    var list = List(4);
    list.Close(Id(2), t0);
    list.Close(Id(3), t0);
    Assert(list.TakeExpired(t0.AddSeconds(7.9)).Count == 0);
    var due = list.TakeExpired(t0 + SheetTabList.UndoWindow);
    Assert(due.Select(sheet => sheet.Id).SequenceEqual([Id(2), Id(3)]));
    Assert(list.DueAt is null && list.Closed.Count == 0 && list.TotalCount == 2);
    Assert(list.TakeExpired(t0.AddHours(1)).Count == 0);
    Assert(list.Undo(t0) is null);
});
Test("shutdown takes everything regardless of the deadline", () =>
{
    var list = List(3);
    list.Close(Id(3), t0);
    Assert(list.TakeAll().Single().Id == Id(3));
    Assert(list.DueAt is null);
});
Test("waiting closes count toward the limit and keep their names", () =>
{
    var list = List(SheetTabList.MaxSheets);
    list.Close(Id(2), t0);
    Assert(!list.CanCreate && list.TotalCount == SheetTabList.MaxSheets);
    Assert(list.UniqueName(n => "Sheet " + n) == "Sheet 257");
    list.TakeExpired(t0.AddMinutes(1));
    Assert(list.CanCreate);
    Assert(list.UniqueName(n => "Sheet " + n) == "Sheet 2");
});
Test("a catalog refresh keeps waiting closes hidden and in place", () =>
{
    var sheets = Sheets(4);
    var list = new SheetTabList();
    list.Update(sheets, sheets[0].Id);
    list.Close(Id(3), t0);
    list.Update(sheets.Append(new SheetTab(Id(5), "Sheet 5")), Id(1));
    Assert(Names(list) == "1,2,4,5" && list.Closed.Count == 1);
    list.Undo(t0);
    Assert(Names(list) == "1,2,3,4,5");
});
Test("a sheet removed elsewhere stops waiting", () =>
{
    var sheets = Sheets(3);
    var list = new SheetTabList();
    list.Update(sheets, sheets[0].Id);
    list.Close(Id(3), t0);
    list.Update(sheets.Take(2), Id(1));
    Assert(list.Closed.Count == 0 && list.DueAt is null);
    Assert(list.Undo(t0) is null);
});
Test("a catalog that names a waiting sheet as active falls back to a visible one", () =>
{
    var sheets = Sheets(3);
    var list = new SheetTabList();
    list.Update(sheets, sheets[0].Id);
    list.Close(Id(2), t0);
    list.Update(sheets, Id(2));
    Assert(list.ActiveId == Id(1));
});
Test("sync leaving only a waiting sheet makes it the visible last sheet", () =>
{
    var sheets = Sheets(2);
    var list = new SheetTabList();
    list.Update(sheets, Id(2));
    list.Close(Id(1), t0);
    list.Update(sheets.Take(1), Id(2)); // another PC deleted the active sheet
    Assert(Names(list) == "1" && list.ActiveId == Id(1));
    Assert(list.Closed.Count == 0 && list.DueAt is null);
    Assert(list.TakeAll().Count == 0);
});
Test("a group delete is one change and always leaves a sheet", () =>
{
    var directory = Path.Combine(Path.GetTempPath(), "qnotch-calculator-tests", Guid.NewGuid().ToString("N"));
    try
    {
        using var store = new WorkspaceStore(directory);
        var first = store.Load().Workspace.ActiveSheetId;
        var second = store.Create("Two").ActiveSheetId;
        var third = store.Create("Three").ActiveSheetId;
        var left = store.DeleteMany([second, third]);
        Assert(left.Sheets.Length == 1 && left.Sheets[0].Id == first && left.ActiveSheetId == first);
        var refused = false;
        try { store.DeleteMany([first]); }
        catch (InvalidDataException) { refused = true; }
        Assert(refused && store.Open(first).Document.Id == first);
    }
    finally { try { Directory.Delete(directory, true); } catch (IOException) { } }
});
Test("a crash during the window loses nothing: the store still holds the closed sheet", () =>
{
    var directory = Path.Combine(Path.GetTempPath(), "qnotch-calculator-tests", Guid.NewGuid().ToString("N"));
    try
    {
        Guid kept;
        using (var store = new WorkspaceStore(directory))
        {
            var workspace = store.Load().Workspace;
            var first = workspace.ActiveSheetId;
            workspace = store.Create("Keep me", "1 + 1");
            kept = workspace.ActiveSheetId;
            var list = new SheetTabList();
            list.Update(workspace.Sheets.Select(s => new SheetTab(s.Id, s.Name)), kept);
            Assert(list.Close(kept, t0, first) is not null);
            store.Select(first);
            // No delete yet: the process ends here.
        }
        using (var reopened = new WorkspaceStore(directory))
        {
            var workspace = reopened.Load().Workspace;
            Assert(workspace.Sheets.Any(s => s.Id == kept && s.Name == "Keep me"));
            Assert(reopened.Open(kept).Document.Source == "1 + 1");
            Assert(workspace.ActiveSheetId != kept);
        }
    }
    finally { try { Directory.Delete(directory, true); } catch (IOException) { } }
});

Console.WriteLine(failures == 0 ? $"All {checks} calculator tab checks passed" : $"{failures} of {checks} calculator tab checks failed");
return failures == 0 ? 0 : 1;

void Test(string name, Action body)
{
    checks++;
    try { body(); Console.WriteLine("ok   " + name); }
    catch (Exception ex) { failures++; Console.WriteLine($"FAIL {name}: {ex.Message}"); }
}

static void Assert(bool condition, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
{
    if (!condition) throw new InvalidOperationException("assertion failed at line " + line);
}
