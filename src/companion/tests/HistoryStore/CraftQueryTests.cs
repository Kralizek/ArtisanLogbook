using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;

using NUnit.Framework;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace Tests.HistoryStore;

[TestFixture]
public sealed class CraftQueryTests
{
    private string _directory = null!;
    private string _path = null!;
    private static readonly GameContext Retail = new(GameProject.Retail);
    private static readonly GameContext Forever = new(GameProject.Forever, "progression");
    private static readonly CharacterIdentity Character = new("character");

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.CraftQuery", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _path = Path.Combine(_directory, "history.duckdb");
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public void PagesUseChronologicalOrderWithOffsetsTicksAndIdentityTieBreakers()
    {
        using Store store = new(_path);
        DateTimeOffset instant = new(2026, 1, 1, 1, 0, 0, TimeSpan.FromHours(1));
        CraftObservation[] observations =
        [
            Craft("z", instant.AddTicks(1)),
            Craft("b", instant.ToOffset(TimeSpan.FromHours(-5))),
            Craft("a", instant),
            Craft("old", instant.AddTicks(-1))
        ];
        foreach (CraftObservation observation in observations)
            Assert.That(store.Write(observation).Status, Is.EqualTo(CraftWriteStatus.Inserted));

        CraftPage first = store.QueryCrafts(new(), 2);
        CraftPage second = store.QueryCrafts(new(), 2, first.EndPosition);
        Assert.Multiple(() =>
        {
            Assert.That(first.Crafts.Select(x => x.Facts.Identity.Observation), Is.EqualTo(new[] { "z", "a" }));
            Assert.That(second.Crafts.Select(x => x.Facts.Identity.Observation), Is.EqualTo(new[] { "b", "old" }));
            Assert.That(first.HasNextPage, Is.True);
            Assert.That(second.HasNextPage, Is.False);
            Assert.That(store.QueryCrafts(new(From: instant, To: instant)).Crafts.Select(x => x.Facts.Identity.Observation),
                Is.EqualTo(new[] { "a", "b" }));
        });
    }

    [Test]
    public void CombinedFiltersAreContextScopedAndPreserveCanonicalChildFacts()
    {
        using Store store = new(_path);
        DateTimeOffset now = DateTimeOffset.Parse("2026-01-02T00:00:00Z");
        CraftObservation expected = Craft("one", now) with
        {
            RecipeId = 12,
            ProfessionId = 34,
            ProfessionExpansionKey = "expansion",
            Reagents = [new(56, null, 0.123456789012345678m)],
            Outputs = [new(78, null, 5_000_000_000L), new(78, 1, null)],
            HasIngenuityProc = false,
            ConcentrationSpent = 0,
            Provenance = new("source"),
            ConfigurationEvidence = [new("source", 197, "configuration snapshot")]
        };
        CraftObservation otherContext = expected with { Identity = new("origin", "other"), Game = Forever };
        CraftObservation unknown = Craft("unknown", now.AddSeconds(-1));
        foreach (CraftObservation observation in new[] { expected, otherContext, unknown })
            Assert.That(store.Write(observation).Status, Is.EqualTo(CraftWriteStatus.Inserted));

        CraftQuery filter = new(Retail, Character, 12, 34, "expansion", now, now, 56, 78);
        CraftPage page = store.QueryCrafts(filter);
        Assert.That(page.Crafts, Has.Count.EqualTo(1));
        CraftObservation actual = page.Crafts[0].Facts;
        Assert.Multiple(() =>
        {
            Assert.That(actual, Is.EqualTo(expected with { Provenance = null }));
            Assert.That(actual.Reagents![0].ReturnedQuantity, Is.EqualTo(0.123456789012345678m));
            Assert.That(actual.Outputs, Has.Count.EqualTo(2));
            Assert.That(actual.Provenance, Is.Null);
            Assert.That(store.QueryCrafts(new(Game: Forever, InputItemId: 56)).Crafts.Single().Facts.Identity,
                Is.EqualTo(otherContext.Identity));
            CraftObservation unobserved = store.QueryCrafts(new(Game: Retail)).Crafts.Single(x => x.Facts.Identity == unknown.Identity).Facts;
            Assert.That(unobserved.Reagents, Is.Null);
            Assert.That(unobserved.Outputs, Is.Null);
        });
        Assert.That(store.Write(actual).Status, Is.EqualTo(CraftWriteStatus.AlreadyPresent));
        CraftObservation persisted = store.Read(expected.Identity)!;
        Assert.Multiple(() =>
        {
            Assert.That(persisted.Provenance, Is.EqualTo(expected.Provenance));
            Assert.That(persisted.ConfigurationEvidence, Is.EqualTo(expected.ConfigurationEvidence));
        });
    }

    [Test]
    public void CriteriaAndCancellationAreValidated()
    {
        using Store store = new(_path);
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        Assert.Multiple(() =>
        {
            Assert.Throws<ArgumentException>(() => store.QueryCrafts(new(RecipeId: 1)));
            Assert.Throws<ArgumentException>(() => store.QueryCrafts(new(Game: Retail, InputItemId: 0)));
            Assert.Throws<ArgumentOutOfRangeException>(() => store.QueryCrafts(new(), 101));
            Assert.Throws<OperationCanceledException>(() => store.QueryCrafts(new(), cancellationToken: cancellation.Token));
        });
    }

    [Test]
    public void ContinuationSeesLaterImportsOnlyBeyondItsPosition()
    {
        using Store store = new(_path);
        DateTimeOffset now = DateTimeOffset.Parse("2026-01-02T00:00:00Z");
        Assert.That(store.Write(Craft("newest", now)).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("oldest", now.AddSeconds(-3))).IsSuccessful, Is.True);
        CraftPage first = store.QueryCrafts(new(), 1);
        Assert.That(store.Write(Craft("inserted-before", now.AddSeconds(1))).IsSuccessful, Is.True);
        Assert.That(store.Write(Craft("inserted-after", now.AddSeconds(-1))).IsSuccessful, Is.True);
        CraftPage second = store.QueryCrafts(new(), 10, first.EndPosition);
        Assert.That(second.Crafts.Select(x => x.Facts.Identity.Observation),
            Is.EqualTo(new[] { "inserted-after", "oldest" }));
    }

    [Test]
    public async Task HeadersAndChildrenShareASnapshotDuringAnImport()
    {
        using ManualResetEventSlim selected = new();
        using ManualResetEventSlim resume = new();
        using Store store = new(_path)
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint != "CraftPageHeaders") return;
                selected.Set();
                if (!resume.Wait(TimeSpan.FromSeconds(20)))
                    throw new TimeoutException("Page read did not resume.");
            }
        };
        CraftObservation initial = Craft("one", DateTimeOffset.Parse("2026-01-02T00:00:00Z"));
        Assert.That(store.Write(initial).IsSuccessful, Is.True);
        Task<CraftPage> read = Task.Run(() => store.QueryCrafts(new()));
        try
        {
            Assert.That(selected.Wait(TimeSpan.FromSeconds(20)), Is.True);
            Assert.That(store.Write(initial with { Reagents = [new(10, 2, null)] }).IsSuccessful, Is.True);
        }
        finally
        {
            resume.Set();
        }
        CraftPage page = await read.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.That(page.Crafts.Single().Facts.Reagents, Is.Null);
        Assert.That(store.Read(initial.Identity)!.Reagents, Has.Count.EqualTo(1));
    }

    [Test]
    public void TimestampOrderingPreservesTicksBeforeUnixEpoch()
    {
        using Store store = new(_path);
        DateTimeOffset instant = DateTimeOffset.UnixEpoch.AddTicks(-10);
        foreach (CraftObservation observation in new[] { Craft("a", instant), Craft("b", instant.AddTicks(1)) })
            Assert.That(store.Write(observation).IsSuccessful, Is.True);
        Assert.That(store.QueryCrafts(new()).Crafts.Select(c => c.Facts.Identity.Observation),
            Is.EqualTo(new[] { "b", "a" }));
    }

    [Test]
    public void CharacterBatchPreservesIndependentPositionsAndExactContexts()
    {
        int batches = 0;
        using Store store = new(_path)
        {
            ReadCheckpoint = checkpoint =>
            {
                if (checkpoint == "CharacterCraftPageHeaders") batches++;
            }
        };
        DateTimeOffset instant = DateTimeOffset.Parse("2026-01-02T00:00:00Z");
        CharacterIdentity other = new("other");
        foreach (CraftObservation observation in new[]
        {
            Craft("new", instant.AddTicks(1)) with { Reagents = [new(10, 1, null)] },
            Craft("same", instant),
            Craft("old", instant.AddTicks(-1)),
            Craft("other-new", instant) with { Character = other, Outputs = [new(11, null, 1)] },
            Craft("foreign", instant) with { Game = Forever }
        })
            Assert.That(store.Write(observation).IsSuccessful, Is.True);

        CharacterCraftPageRequest retail = new(new(Retail, Character), 1);
        CharacterCraftPageRequest otherPage = new(new(Retail, other), 1);
        CharacterCraftPageRequest foreign = new(new(Forever, Character), 1);
        IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage> pages = store.QueryCharacterCraftPages([retail, otherPage, foreign]);
        Assert.Multiple(() =>
        {
            Assert.That(batches, Is.EqualTo(1));
            Assert.That(pages[retail].Crafts.Single().Facts.Identity.Observation, Is.EqualTo("new"));
            Assert.That(pages[retail].HasNextPage, Is.True);
            Assert.That(pages[otherPage].Crafts.Single().Facts.Outputs, Has.Count.EqualTo(1));
            Assert.That(pages[otherPage].HasNextPage, Is.False);
            Assert.That(pages[foreign].Crafts.Single().Facts.Identity.Observation, Is.EqualTo("foreign"));
        });
        CharacterCraftPageRequest second = retail with { After = pages[retail].EndPosition, First = 2 };
        IReadOnlyDictionary<CharacterCraftPageRequest, CraftPage> continuation = store.QueryCharacterCraftPages([second, otherPage]);
        Assert.That(continuation[second].Crafts.Select(x => x.Facts.Identity.Observation), Is.EqualTo(new[] { "same", "old" }));
        Assert.That(continuation[second].HasNextPage, Is.False);
    }

    private static CraftObservation Craft(string id, DateTimeOffset at) =>
        new(new("origin", id), Retail, at, null, Character);
}
