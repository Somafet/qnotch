using Calc.Documents;
using QNotch.Calculator;

namespace QNotch.Calculator.Tests;

/// <summary>Calculator tab checks: what closing, undoing and expiring do to the tab list, and that a closed sheet stays in the real store
/// until its window ends. No window, no network.</summary>
public sealed class SheetTabListTests
{
    private static readonly DateTimeOffset t0 = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

    private static SheetTab[] Sheets(int count) => Enumerable.Range(1, count).Select(i => new SheetTab(new Guid(i, 0, 0, new byte[8]), "Sheet " + i)).ToArray();
    private static SheetTabList List(int count, int active = 0)
    {
        var sheets = Sheets(count);
        var list = new SheetTabList();
        list.Update(sheets, sheets[active].Id);
        return list;
    }
    private static Guid Id(int oneBased) => new(oneBased, 0, 0, new byte[8]);
    private static string Names(SheetTabList list) => string.Join(",", list.Visible.Select(tab => tab.Name.Replace("Sheet ", "")));

    [Fact(DisplayName = "closing an inactive tab leaves the active sheet")]
    public void ClosingAnInactiveTabLeavesTheActiveSheet()
    {
        var list = List(4, 1);
        var closed = list.Close(Id(4), t0);
        Assert.True(closed is { WasActive: false, Position: 3 });
        Assert.True(list.ActiveId == Id(2));
        Assert.True(Names(list) == "1,2,3");
    }

    [Fact(DisplayName = "closing the active tab activates its right neighbor, or the left one at the end")]
    public void ClosingTheActiveTabActivatesItsRightNeighborOrTheLeftOneAtTheEnd()
    {
        var list = List(4, 1);
        list.Close(Id(2), t0);
        Assert.True(list.ActiveId == Id(3));
        var last = List(3, 2);
        last.Close(Id(3), t0);
        Assert.True(last.ActiveId == Id(2));
    }

    [Fact(DisplayName = "neighbors go outward, right first")]
    public void NeighborsGoOutwardRightFirst() =>
        Assert.True(string.Join(",", List(5).NeighborsOf(Id(3)).Select(id => id.ToByteArray()[0])) == "4,2,5,1");

    [Fact(DisplayName = "a chosen neighbor wins over the nearest one")]
    public void AChosenNeighborWinsOverTheNearestOne()
    {
        var list = List(4, 1);
        list.Close(Id(2), t0, Id(1));
        Assert.True(list.ActiveId == Id(1));
    }

    [Fact(DisplayName = "the last visible sheet cannot be closed")]
    public void TheLastVisibleSheetCannotBeClosed()
    {
        var list = List(2);
        Assert.True(list.Close(Id(2), t0) is not null);
        Assert.True(list.CanClose(Id(1)) == CloseVerdict.LastSheet);
        Assert.True(list.Close(Id(1), t0) is null);
        Assert.True(Names(list) == "1" && list.ActiveId == Id(1));
    }

    [Fact(DisplayName = "the last sheet closes once a replacement is in front, and undo brings it back in front")]
    public void TheLastSheetClosesOnceAReplacementIsInFrontAndUndoBringsItBackInFront()
    {
        // The surface creates an empty sheet first, then closes the old one as a tab that was in front.
        var list = List(1);
        list.Update([.. Sheets(2)], Id(2));
        var closed = list.Close(Id(1), t0, wasActive: true);
        Assert.True(closed is { WasActive: true, Position: 0 });
        Assert.True(Names(list) == "2" && list.ActiveId == Id(2));
        Assert.True(list.Undo(t0)?.Id == Id(1));
        Assert.True(list.ActiveId == Id(1) && Names(list) == "1,2");
    }

    [Fact(DisplayName = "closing all but one quickly stops at one")]
    public void ClosingAllButOneQuicklyStopsAtOne()
    {
        var list = List(6, 2);
        foreach (var tab in list.Visible.ToArray()) list.Close(tab.Id, t0);
        Assert.True(list.Visible.Count == 1 && list.Closed.Count == 5);
        Assert.True(list.ActiveId == list.Visible[0].Id);
    }

    [Fact(DisplayName = "an unknown or already closed sheet is refused")]
    public void AnUnknownOrAlreadyClosedSheetIsRefused()
    {
        var list = List(3);
        Assert.True(list.CanClose(Id(9)) == CloseVerdict.Unknown);
        list.Close(Id(3), t0);
        Assert.True(list.CanClose(Id(3)) == CloseVerdict.Unknown);
        Assert.True(list.Close(Id(3), t0) is null);
        Assert.True(!list.SetActive(Id(3)));
    }

    [Fact(DisplayName = "undo restores the most recent close, at its old place")]
    public void UndoRestoresTheMostRecentCloseAtItsOldPlace()
    {
        var list = List(5);
        list.Close(Id(2), t0);
        list.Close(Id(4), t0);
        Assert.True(Names(list) == "1,3,5");
        Assert.True(list.Undo(t0)?.Id == Id(4));
        Assert.True(Names(list) == "1,3,4,5");
        Assert.True(list.Undo(t0)?.Id == Id(2));
        Assert.True(Names(list) == "1,2,3,4,5");
        Assert.True(list.Undo(t0) is null);
    }

    [Fact(DisplayName = "undo brings an active sheet back in front, an inactive one stays behind")]
    public void UndoBringsAnActiveSheetBackInFrontAnInactiveOneStaysBehind()
    {
        var active = List(3, 1);
        active.Close(Id(2), t0);
        active.SetActive(Id(1));   // the user moved on
        active.Undo(t0);
        Assert.True(active.ActiveId == Id(2));
        var inactive = List(3, 1);
        inactive.Close(Id(3), t0);
        inactive.Undo(t0);
        Assert.True(inactive.ActiveId == Id(2));
    }

    [Fact(DisplayName = "every close and undo moves the one deadline on")]
    public void EveryCloseAndUndoMovesTheOneDeadlineOn()
    {
        var list = List(4);
        list.Close(Id(2), t0);
        Assert.True(list.DueAt == t0 + SheetTabList.UndoWindow);
        var later = t0.AddSeconds(5);
        list.Close(Id(3), later);
        Assert.True(list.DueAt == later + SheetTabList.UndoWindow);
        Assert.True(list.TakeExpired(t0 + SheetTabList.UndoWindow).Count == 0); // the first close did not expire on its own
        var undone = later.AddSeconds(1);
        list.Undo(undone);
        Assert.True(list.DueAt == undone + SheetTabList.UndoWindow);
        list.Undo(undone);
        Assert.True(list.DueAt is null);
    }

    [Fact(DisplayName = "expiry hands over every waiting close, oldest first, once")]
    public void ExpiryHandsOverEveryWaitingCloseOldestFirstOnce()
    {
        var list = List(4);
        list.Close(Id(2), t0);
        list.Close(Id(3), t0);
        Assert.True(list.TakeExpired(t0.AddSeconds(7.9)).Count == 0);
        var due = list.TakeExpired(t0 + SheetTabList.UndoWindow);
        Assert.True(due.Select(sheet => sheet.Id).SequenceEqual([Id(2), Id(3)]));
        Assert.True(list.DueAt is null && list.Closed.Count == 0 && list.TotalCount == 2);
        Assert.True(list.TakeExpired(t0.AddHours(1)).Count == 0);
        Assert.True(list.Undo(t0) is null);
    }

    [Fact(DisplayName = "shutdown takes everything regardless of the deadline")]
    public void ShutdownTakesEverythingRegardlessOfTheDeadline()
    {
        var list = List(3);
        list.Close(Id(3), t0);
        Assert.True(list.TakeAll().Single().Id == Id(3));
        Assert.True(list.DueAt is null);
    }

    [Fact(DisplayName = "waiting closes count toward the limit and keep their names")]
    public void WaitingClosesCountTowardTheLimitAndKeepTheirNames()
    {
        var list = List(SheetTabList.MaxSheets);
        list.Close(Id(2), t0);
        Assert.True(!list.CanCreate && list.TotalCount == SheetTabList.MaxSheets);
        Assert.True(list.UniqueName(n => "Sheet " + n) == "Sheet 257");
        list.TakeExpired(t0.AddMinutes(1));
        Assert.True(list.CanCreate);
        Assert.True(list.UniqueName(n => "Sheet " + n) == "Sheet 2");
    }

    [Fact(DisplayName = "a catalog refresh keeps waiting closes hidden and in place")]
    public void ACatalogRefreshKeepsWaitingClosesHiddenAndInPlace()
    {
        var sheets = Sheets(4);
        var list = new SheetTabList();
        list.Update(sheets, sheets[0].Id);
        list.Close(Id(3), t0);
        list.Update(sheets.Append(new SheetTab(Id(5), "Sheet 5")), Id(1));
        Assert.True(Names(list) == "1,2,4,5" && list.Closed.Count == 1);
        list.Undo(t0);
        Assert.True(Names(list) == "1,2,3,4,5");
    }

    [Fact(DisplayName = "a sheet removed elsewhere stops waiting")]
    public void ASheetRemovedElsewhereStopsWaiting()
    {
        var sheets = Sheets(3);
        var list = new SheetTabList();
        list.Update(sheets, sheets[0].Id);
        list.Close(Id(3), t0);
        list.Update(sheets.Take(2), Id(1));
        Assert.True(list.Closed.Count == 0 && list.DueAt is null);
        Assert.True(list.Undo(t0) is null);
    }

    [Fact(DisplayName = "a catalog that names a waiting sheet as active falls back to a visible one")]
    public void ACatalogThatNamesAWaitingSheetAsActiveFallsBackToAVisibleOne()
    {
        var sheets = Sheets(3);
        var list = new SheetTabList();
        list.Update(sheets, sheets[0].Id);
        list.Close(Id(2), t0);
        list.Update(sheets, Id(2));
        Assert.True(list.ActiveId == Id(1));
    }

    [Fact(DisplayName = "sync leaving only a waiting sheet makes it the visible last sheet")]
    public void SyncLeavingOnlyAWaitingSheetMakesItTheVisibleLastSheet()
    {
        var sheets = Sheets(2);
        var list = new SheetTabList();
        list.Update(sheets, Id(2));
        list.Close(Id(1), t0);
        list.Update(sheets.Take(1), Id(2)); // another PC deleted the active sheet
        Assert.True(Names(list) == "1" && list.ActiveId == Id(1));
        Assert.True(list.Closed.Count == 0 && list.DueAt is null);
        Assert.True(list.TakeAll().Count == 0);
    }

    [Fact(DisplayName = "a group delete is one change and always leaves a sheet")]
    public void AGroupDeleteIsOneChangeAndAlwaysLeavesASheet()
    {
        var directory = Path.Combine(Path.GetTempPath(), "qnotch-calculator-tests", Guid.NewGuid().ToString("N"));
        try
        {
            using var store = new WorkspaceStore(directory);
            var first = store.Load().Workspace.ActiveSheetId;
            var second = store.Create("Two").ActiveSheetId;
            var third = store.Create("Three").ActiveSheetId;
            var left = store.DeleteMany([second, third]);
            Assert.True(left.Sheets.Length == 1 && left.Sheets[0].Id == first && left.ActiveSheetId == first);
            var refused = false;
            try { store.DeleteMany([first]); }
            catch (InvalidDataException) { refused = true; }
            Assert.True(refused && store.Open(first).Document.Id == first);
        }
        finally { try { Directory.Delete(directory, true); } catch (IOException) { } }
    }

    [Fact(DisplayName = "a crash during the window loses nothing: the store still holds the closed sheet")]
    public void ACrashDuringTheWindowLosesNothingTheStoreStillHoldsTheClosedSheet()
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
                Assert.True(list.Close(kept, t0, first) is not null);
                store.Select(first);
                // No delete yet: the process ends here.
            }
            using (var reopened = new WorkspaceStore(directory))
            {
                var workspace = reopened.Load().Workspace;
                Assert.Contains(workspace.Sheets, s => s.Id == kept && s.Name == "Keep me");
                Assert.True(reopened.Open(kept).Document.Source == "1 + 1");
                Assert.True(workspace.ActiveSheetId != kept);
            }
        }
        finally { try { Directory.Delete(directory, true); } catch (IOException) { } }
    }
}
