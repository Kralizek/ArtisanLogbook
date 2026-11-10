using ArtisanLogbook.Runtime;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class MonitoringCheckpointTests
{
    private static readonly string Source = SourceCatalog.IdFor("/source");
    private static readonly string Other = SourceCatalog.IdFor("/other");
    private static readonly string FirstHash = new('A', 64);
    private static readonly string SecondHash = new('B', 64);
    private static readonly DateTimeOffset Now = DateTimeOffset.UnixEpoch;

    [Test]
    public void PureTransitionsPreserveObservedChangesAndNewestSuccessfulReceipt()
    {
        SourceCheckpoint checkpoint = new(SecondHash);
        checkpoint = checkpoint.Complete(new(2, FirstHash, CheckpointAttemptOutcome.Successful, Now), TimeSpan.Zero);
        checkpoint = checkpoint.Complete(new(3, SecondHash, CheckpointAttemptOutcome.Failed, Now), TimeSpan.Zero);
        checkpoint = checkpoint.Complete(new(1, SecondHash, CheckpointAttemptOutcome.Successful, Now), TimeSpan.Zero);
        Assert.Multiple(() =>
        {
            Assert.That(checkpoint.Observed, Is.EqualTo(SecondHash));
            Assert.That(checkpoint.Successful!.Sequence, Is.EqualTo(2));
            Assert.That(checkpoint.Successful.Fingerprint, Is.EqualTo(FirstHash));
            Assert.That(checkpoint.LastAttempt!.Sequence, Is.EqualTo(3));
            Assert.That(checkpoint.RequiresImport, Is.True);
        });
    }

    [Test]
    public void OlderSuccessDeliveredAfterNewerFailureIsNotLost()
    {
        SourceCheckpoint checkpoint = new(SecondHash);
        checkpoint = checkpoint.Complete(new(2, SecondHash, CheckpointAttemptOutcome.Failed, Now), TimeSpan.Zero);
        checkpoint = checkpoint.Complete(new(1, FirstHash, CheckpointAttemptOutcome.Successful, Now), TimeSpan.Zero);
        Assert.That(checkpoint.Successful!.Fingerprint, Is.EqualTo(FirstHash));
        Assert.That(checkpoint.LastAttempt!.Outcome, Is.EqualTo(CheckpointAttemptOutcome.Failed));
        Assert.That(checkpoint.Complete(checkpoint.LastAttempt, TimeSpan.Zero), Is.EqualTo(checkpoint));
    }

    [Test]
    public void ReappearanceOfPreviouslyIngestedBytesDoesNotRemainPendingAfterAnUnrelatedFailure()
    {
        SourceCheckpoint checkpoint = new(SecondHash);
        checkpoint = checkpoint.Complete(new(1, FirstHash, CheckpointAttemptOutcome.Successful, Now), TimeSpan.Zero);
        checkpoint = checkpoint.Complete(new(2, SecondHash, CheckpointAttemptOutcome.Failed, Now), TimeSpan.Zero);
        checkpoint = checkpoint.Observe(FirstHash);
        Assert.That(checkpoint.NeedsReconciliation, Is.False);
        Assert.That(checkpoint.Successful!.Fingerprint, Is.EqualTo(FirstHash));
        Assert.That(checkpoint.LastAttempt!.Outcome, Is.EqualTo(CheckpointAttemptOutcome.Failed));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task UnsuccessfulImportDoesNotAdvanceSuccessAndCanRetry(bool cancelled)
    {
        MemoryStore store = new();
        using MonitoringCheckpoints checkpoints = new(store);
        checkpoints.Observe(Source, FirstHash);
        long sequence = Reserve(checkpoints);
        checkpoints.Complete(Source, sequence, cancelled ? CheckpointAttemptOutcome.Cancelled : CheckpointAttemptOutcome.Failed, FirstHash, Now);
        await checkpoints.FlushAsync();
        SourceCheckpoint saved = store.Durable.Sources[Source];
        Assert.That(saved.Successful, Is.Null);
        Assert.That(saved.IsEligible(Now), Is.False);
        Assert.That(saved.IsEligible(Now + MonitoringCheckpoints.RetryDelay), Is.True);
        Assert.That(saved.Observe(SecondHash).IsEligible(Now), Is.True, "new bytes bypass the failed-content backoff");
    }

    [Test]
    public async Task SuccessThenFailureBeforeSaveRetainsBothEffectsAndRetryNeedsNoReimport()
    {
        MemoryStore store = new() { Fail = true };
        using MonitoringCheckpoints checkpoints = new(store);
        checkpoints.Observe(Source, FirstHash);
        checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful, FirstHash, Now);
        checkpoints.Observe(Source, SecondHash);
        checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Failed, SecondHash, Now);
        Assert.ThrowsAsync<IOException>(() => checkpoints.FlushAsync());
        Assert.That(checkpoints.Read().IsDirty, Is.True);
        Assert.That(checkpoints.Read().PersistenceFailure, Is.EqualTo("checkpoint-save-failed"));
        Assert.That(store.Durable.Sources, Is.Empty);

        store.Fail = false;
        await checkpoints.FlushAsync();
        Assert.Multiple(() =>
        {
            Assert.That(checkpoints.Read().IsDirty, Is.False);
            Assert.That(checkpoints.Read().PersistenceFailure, Is.Null);
            Assert.That(store.Durable.Sources[Source].Successful!.Fingerprint, Is.EqualTo(FirstHash));
            Assert.That(store.Durable.Sources[Source].LastAttempt!.Outcome, Is.EqualTo(CheckpointAttemptOutcome.Failed));
            Assert.That(store.Durable.NextSequence, Is.EqualTo(2), "persistence retry did not reserve another import");
        });
    }

    [Test]
    public async Task MultipleSuccessesCompactToNewestWithoutACompletionQueue()
    {
        MemoryStore store = new();
        using MonitoringCheckpoints checkpoints = new(store);
        for (int i = 0; i < 10_000; i++)
            checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful,
                i % 2 == 0 ? FirstHash : SecondHash, Now);
        await checkpoints.FlushAsync();
        Assert.That(store.Durable.Sources, Has.Count.EqualTo(1));
        Assert.That(store.Durable.Sources[Source].Successful!.Sequence, Is.EqualTo(10_000));
        Assert.That(store.Durable.Sources[Source].Successful!.Fingerprint, Is.EqualTo(SecondHash));
    }

    [Test]
    public async Task CompletionDuringSaveIsNotAcknowledgedByOlderSnapshotAndConcurrentSavesSerialize()
    {
        MemoryStore store = new() { Block = true };
        using MonitoringCheckpoints checkpoints = new(store);
        checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful, FirstHash, Now);
        Task firstSave = checkpoints.FlushAsync();
        await store.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));

        // This transition must not wait for disk I/O or be acknowledged by the already captured document.
        await Task.Run(() => checkpoints.Complete(Source, Reserve(checkpoints),
            CheckpointAttemptOutcome.Successful, SecondHash, Now)).WaitAsync(TimeSpan.FromSeconds(10));
        Task secondSave = checkpoints.FlushAsync();
        Assert.That(store.SaveCount, Is.EqualTo(1));
        store.Release.SetResult();
        await Task.WhenAll(firstSave, secondSave).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.That(store.SaveCount, Is.EqualTo(2));
        Assert.That(store.Durable.Sources[Source].Successful!.Fingerprint, Is.EqualTo(SecondHash));
        Assert.That(checkpoints.Read().IsDirty, Is.False);
    }

    [Test]
    public async Task FailedPersistenceCannotPruneReceiptOrExceedSourceCapacity()
    {
        MemoryStore store = new() { Fail = true };
        using MonitoringCheckpoints checkpoints = new(store, maximumSources: 1);
        checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful, FirstHash, Now);
        checkpoints.Prune(new HashSet<string>());
        Assert.That(checkpoints.TryReserve([Other], Now, out _), Is.False);
        Assert.ThrowsAsync<IOException>(() => checkpoints.FlushAsync());
        Assert.That(checkpoints.Read().Document.Sources, Has.Count.EqualTo(1));
        store.Fail = false;
        await checkpoints.FlushAsync();
        checkpoints.Prune(new HashSet<string>());
        Assert.That(checkpoints.TryReserve([Other], Now, out _), Is.True);
    }

    [Test]
    public void DefaultCapacityAdmits4096SourcesButRejectsThe4097thWithoutMutation()
    {
        using MonitoringCheckpoints checkpoints = new(new MemoryStore());
        string[] ids = Enumerable.Range(0, 4096).Select(i => SourceCatalog.IdFor($"/source-{i}")).ToArray();
        Assert.That(checkpoints.TryReserve(ids, Now, out var attempts), Is.True);
        Assert.That(attempts, Has.Count.EqualTo(4096));
        CheckpointSnapshot before = checkpoints.Read();
        Assert.That(checkpoints.TryReserve([Other], Now, out _), Is.False);
        Assert.That(checkpoints.Read(), Is.EqualTo(before));
    }

    [Test]
    public async Task RestartDoesNotManufactureSuccessFromAnInterruptedAttempt()
    {
        MemoryStore store = new();
        using (MonitoringCheckpoints checkpoints = new(store))
        {
            checkpoints.Observe(Source, FirstHash);
            Reserve(checkpoints);
            await checkpoints.FlushAsync();
        }
        using MonitoringCheckpoints restarted = new(store);
        Assert.That(restarted.Read().Document.Sources[Source].Successful, Is.Null);
        Assert.That(restarted.Read().Document.Sources[Source].IsEligible(Now), Is.True);
        Assert.That(Reserve(restarted), Is.EqualTo(2));
    }

    [Test]
    public async Task CancelledSaveKeepsReceiptForASeparateRetry()
    {
        MemoryStore store = new() { Block = true };
        using MonitoringCheckpoints checkpoints = new(store);
        checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful, FirstHash, Now);
        using CancellationTokenSource cancellation = new();
        Task save = checkpoints.FlushAsync(cancellation.Token);
        await store.Entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
        await cancellation.CancelAsync();
        Assert.CatchAsync<OperationCanceledException>(async () => await save);
        Assert.That(checkpoints.Read().IsDirty, Is.True);
        Assert.That(checkpoints.Read().Document.Sources[Source].Successful!.Fingerprint, Is.EqualTo(FirstHash));
        store.Block = false;
        await checkpoints.FlushAsync();
        Assert.That(checkpoints.Read().IsDirty, Is.False);
    }

    [Test]
    public void SuccessWithoutExactFingerprintIsRejected()
    {
        using MonitoringCheckpoints checkpoints = new(new MemoryStore());
        checkpoints.Observe(Source, FirstHash);
        long sequence = Reserve(checkpoints);
        Assert.Throws<InvalidOperationException>(() =>
            checkpoints.Complete(Source, sequence, CheckpointAttemptOutcome.Successful, null, Now));
        Assert.That(checkpoints.Read().Document.Sources[Source].Successful, Is.Null);
    }

    [Test]
    public async Task NothingToPersistDoesNotTurnAnExpiredShutdownDeadlineIntoFailure()
    {
        MemoryStore store = new();
        using MonitoringCheckpoints checkpoints = new(store);
        await checkpoints.FlushAsync(new CancellationToken(canceled: true));
        Assert.That(store.SaveCount, Is.Zero);
    }

    [TestCase("""{"version":1,"version":1,"nextSequence":0,"sources":{}}""")]
    [TestCase("""{"version":1,"nextSequence":0,"sources":null}""")]
    [TestCase("""{"version":1,"nextSequence":0,"sources":{},"unknown":true}""")]
    public void MalformedCheckpointDocumentsAreExplicitFailures(string json)
    {
        string path = Path.Combine(Path.GetTempPath(), $"ArtisanLogbook.Checkpoint-{Guid.NewGuid():N}.json");
        try
        {
            File.WriteAllText(path, json);
            Assert.Throws<IOException>(() => new MonitoringCheckpointStore(path).Load());
            Assert.That(File.ReadAllText(path), Is.EqualTo(json));
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task SidecarRoundTripsAndRefusesExternalChangesOrInvalidVersions()
    {
        string directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Checkpoints", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "history.duckdb.monitoring.json");
        try
        {
            MonitoringCheckpointStore store = new(path);
            using (MonitoringCheckpoints checkpoints = new(store))
            {
                checkpoints.Observe(Source, FirstHash);
                checkpoints.Complete(Source, Reserve(checkpoints), CheckpointAttemptOutcome.Successful, FirstHash, Now);
                await checkpoints.FlushAsync();
            }
            CheckpointDocument document = new MonitoringCheckpointStore(path).Load();
            Assert.That(document.Sources[Source].Successful!.Fingerprint, Is.EqualTo(FirstHash));
            Assert.That(await File.ReadAllTextAsync(path), Does.Not.Contain("/source"));
            await File.WriteAllTextAsync(path, """{"version":99}""");
            Assert.ThrowsAsync<IOException>(() => store.SaveAsync(document, CancellationToken.None));
            Assert.Throws<IOException>(() => new MonitoringCheckpointStore(path).Load());
            Assert.That(await File.ReadAllTextAsync(path), Is.EqualTo("""{"version":99}"""));
            Assert.That(Directory.GetFiles(directory, "*.tmp"), Is.Empty);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static long Reserve(MonitoringCheckpoints checkpoints)
    {
        Assert.That(checkpoints.TryReserve([Source], Now, out var attempts), Is.True);
        return attempts[Source];
    }

    internal sealed class MemoryStore() : MonitoringCheckpointStore("/unused.monitoring.json")
    {
        public CheckpointDocument Durable { get; private set; } = CheckpointDocument.Empty;
        public bool Fail { get; set; }
        public bool Block { get; set; }
        public int SaveCount { get; private set; }
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public override CheckpointDocument Load() => Durable;

        public override async Task SaveAsync(CheckpointDocument document, CancellationToken cancellationToken)
        {
            SaveCount++;
            Entered.TrySetResult();
            if (Block) await Release.Task.WaitAsync(cancellationToken);
            if (Fail) throw new IOException("Controlled checkpoint persistence failure.");
            Durable = document;
        }
    }
}
