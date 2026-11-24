using Calc.Core;

namespace Calc.Documents.Tests;

public sealed class DiceRollTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "Calc-dice-tests", Guid.NewGuid().ToString("N"));
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    private static string[] Shown(GeneratedUuidSession session) =>
        SheetEvaluator.Evaluate(session.Source, context: new() { Uuids = session.Context }).Select(r => r.Display).ToArray();

    [Fact]
    public void EnterRollsOnceAndAgainRerollsWithinRange()
    {
        var session = new GeneratedUuidSession("10d6+4\nprose\n2+2");
        Assert.Null(session.Roll(1, false)); Assert.Null(session.Roll(2, true)); Assert.False(session.Enabled);
        var first = session.Roll(0, false)!;
        Assert.True(session.Enabled); Assert.Equal("10d6+4", first.Formula); Assert.Equal(10, first.Faces.Length);
        Assert.All(first.Faces, face => Assert.InRange(face, 1, 6));
        Assert.Null(session.Roll(0, false));
        Assert.Equal((first.Faces.Sum() + 4).ToString(), Shown(session)[0]);
        var faces = new HashSet<string>();
        for (var i = 0; i < 40; i++) faces.Add(string.Join(',', session.Roll(0, true)!.Faces));
        Assert.True(faces.Count > 1);
        Assert.Equal((session.Rolled(0)!.Faces.Sum() + 4).ToString(), Shown(session)[0]);
    }

    [Fact]
    public void RollFollowsItsStatementUntilTheDiceChange()
    {
        var session = new GeneratedUuidSession("2d6+3");
        var roll = session.Roll(0, false)!;
        // Enter at the end of the line, then a line inserted above: the roll moves with its statement.
        session.Apply("2d6+3\n", 5, 0, 1); session.Apply("x = 1\n2d6+3\n", 0, 0, 6);
        Assert.Equal(roll.Faces, session.Rolled(1)!.Faces);
        // Labels and spacing keep it.
        session.Apply("x = 1\nHit 2d6 + 3\n");
        Assert.Equal(roll.Faces, session.Rolled(1)!.Faces);
        // Changing the dice clears it; undo restores the earlier roll.
        var edit = session.Apply("x = 1\nHit 2d8 + 3\n");
        Assert.Null(session.Rolled(1));
        Assert.Equal("5–19", Shown(session)[1]);
        edit.Undo(); session.ReplaySource("x = 1\nHit 2d6 + 3\n");
        Assert.Equal(roll.Faces, session.Rolled(1)!.Faces);
    }

    [Fact]
    public void RollsPersistAsStateVersionTwo()
    {
        Guid id; int[] faces;
        using (var store = new WorkspaceStore(directory))
        {
            id = store.Load().Workspace.ActiveSheetId; var doc = store.Open(id).Document;
            var session = new GeneratedUuidSession("uuid\ndmg = 3d8+2\ndmg * 2");
            faces = session.Roll(1, false)!.Faces;
            var snapshot = session.Snapshot!;
            Assert.Equal(2, snapshot.Version); Assert.Single(snapshot.Dice!);
            store.Save(doc with { Version = 2, Source = session.Source, GeneratedUuids = snapshot });
        }
        using var reopened = new WorkspaceStore(directory); reopened.Load();
        var saved = reopened.Open(id).Document;
        var loaded = new GeneratedUuidSession(saved.Source, saved.GeneratedUuids);
        Assert.Equal(faces, loaded.Rolled(1)!.Faces);
        Assert.Equal(((faces.Sum() + 2) * 2).ToString(), Shown(loaded)[2]);
    }

    [Fact]
    public void CrunchyCritRollsSavedAsCritWaitForANewRoll()
    {
        // Before 18 November 2026 `crit 2d6+3` was the crunchy critical: two stored faces. It now means 4d6+3.
        var session = new GeneratedUuidSession("crit 2d6+3\n1d8");
        var kept = session.Roll(1, false)!;
        var id = session.Snapshot!.Statements[0];
        var old = session.Snapshot! with { Dice = [new DiceBinding(id, "crit 2d6+3", [3, 6]), kept] };
        GeneratedUuidSession.Validate(session.Source, old);
        var loaded = new GeneratedUuidSession(session.Source, old);
        Assert.Null(loaded.Rolled(0)); Assert.Equal(kept.Faces, loaded.Rolled(1)!.Faces);
        Assert.Equal("7–27", Shown(loaded)[0]);
        var crit = loaded.Roll(0, false)!;
        Assert.Equal(4, crit.Faces.Length);
        Assert.Equal((crit.Faces.Sum() + 3).ToString(), Shown(loaded)[0]);
        // Rewriting the line as `crit!` makes the crunchy critical: 12 + 2d6 + 3.
        loaded.Apply("crit! 2d6+3\n1d8");
        var crunchy = loaded.Roll(0, false)!;
        Assert.Equal(2, crunchy.Faces.Length);
        Assert.Equal((12 + crunchy.Faces.Sum() + 3).ToString(), Shown(loaded)[0]);
    }

    [Fact]
    public void StateVersionMustMatchItsRolls()
    {
        var session = new GeneratedUuidSession("2d6"); session.Roll(0, false);
        var state = session.Snapshot!;
        GeneratedUuidSession.Validate("2d6", state);
        // A version-1 reader refuses rolls instead of discarding them; a version-2 claim without rolls is invalid.
        Assert.Throws<InvalidDataException>(() => GeneratedUuidSession.Validate("2d6", state with { Version = 1 }));
        Assert.Throws<InvalidDataException>(() => GeneratedUuidSession.Validate("2d6", state with { Dice = null }));
        Assert.Throws<UnsupportedDocumentVersionException>(() => GeneratedUuidSession.Validate("2d6", state with { Version = 3 }));
        // A roll that no longer fits its formula is dropped on load, never misread; the source and other rolls stay.
        var impossible = state with { Dice = [state.Dice![0] with { Faces = [9, 1] }] };
        GeneratedUuidSession.Validate("2d6", impossible);
        Assert.Null(new GeneratedUuidSession("2d6", impossible).Rolled(0));
        Assert.Throws<InvalidDataException>(() => GeneratedUuidSession.Validate("2d6", state with { Dice = [state.Dice![0] with { Faces = null! }] }));
        // Deleting every rolled line returns to UUID-only state.
        session.Apply("");
        Assert.Equal(1, session.Snapshot!.Version); Assert.Null(session.Snapshot.Dice);
    }

    [Fact]
    public void RollAllAndAdoptRollsServeOneShotTotals()
    {
        var sheet = new GeneratedUuidSession("2d6\nd20+1\nprose"); sheet.Enable();
        Assert.Equal(2, sheet.RollAll()); Assert.Equal(0, sheet.RollAll());
        var total = new GeneratedUuidSession("2d6\nd20+1\nprose\n\nL1\nL2\nsum"); total.Enable(); total.AdoptRolls(sheet);
        Assert.Equal(sheet.Rolled(0)!.Faces, total.Rolled(0)!.Faces); Assert.Equal(sheet.Rolled(1)!.Faces, total.Rolled(1)!.Faces);
        var shown = Shown(total);
        Assert.Equal((int.Parse(shown[0]) + int.Parse(shown[1])).ToString(), shown[^1]);
    }
}
