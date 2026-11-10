using System.Security.Cryptography;
using System.Text;

using ArtisanLogbook.ImportService;

using NUnit.Framework;

namespace Tests.ImportService;

[TestFixture]
public sealed class SavedVariablesSnapshotReaderTests
{
    private string _directory = null!;
    private string _path = null!;

    [SetUp]
    public void SetUp()
    {
        _directory = Path.Combine(Path.GetTempPath(), "ArtisanLogbook.Snapshots", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _path = Path.Combine(_directory, "source.lua");
    }

    [TearDown]
    public void TearDown() => Directory.Delete(_directory, recursive: true);

    [Test]
    public async Task FingerprintIncludesOriginalUtf8BytesAndBom()
    {
        byte[] bytes = [0xef, 0xbb, 0xbf, .. Encoding.UTF8.GetBytes("ArtisanLogbookDB = {}")];
        await File.WriteAllBytesAsync(_path, bytes);
        SavedVariablesSnapshot snapshot = await new SavedVariablesSnapshotReader(quietPeriod: TimeSpan.Zero).ReadAsync(_path);
        Assert.That(snapshot.Fingerprint, Is.EqualTo(Convert.ToHexString(SHA256.HashData(bytes))));
        Assert.That(snapshot.Content[0], Is.EqualTo('\ufeff'));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task SameLengthSameTimestampRewriteOrAtomicReplacementIsUnstable(bool replace)
    {
        await File.WriteAllTextAsync(_path, "first");
        DateTime timestamp = File.GetLastWriteTimeUtc(_path);
        MutatingReader reader = new(() =>
        {
            if (replace)
            {
                File.WriteAllText(_path + ".new", "other");
                File.SetLastWriteTimeUtc(_path + ".new", timestamp);
                File.Move(_path + ".new", _path, overwrite: true);
            }
            else
            {
                File.WriteAllText(_path, "other");
                File.SetLastWriteTimeUtc(_path, timestamp);
            }
        });
        SourceSnapshotException exception = Assert.ThrowsAsync<SourceSnapshotException>(() => reader.ReadAsync(_path))!;
        Assert.That(exception.Code, Is.EqualTo("source-changed-during-read"));
        SavedVariablesSnapshot stable = await new SavedVariablesSnapshotReader(quietPeriod: TimeSpan.Zero).ReadAsync(_path);
        Assert.That(stable.Content, Is.EqualTo("other"));
    }

    [Test]
    public async Task InvalidEncodingIsRejectedAndCancellationIsNotConvertedToFailure()
    {
        await File.WriteAllBytesAsync(_path, [0xff]);
        SavedVariablesSnapshotReader reader = new(quietPeriod: TimeSpan.Zero);
        Assert.That(Assert.ThrowsAsync<SourceSnapshotException>(() => reader.ReadAsync(_path))!.Code,
            Is.EqualTo("invalid-source-encoding"));
        using CancellationTokenSource cancellation = new();
        cancellation.Cancel();
        Assert.ThrowsAsync<OperationCanceledException>(() => reader.ReadAsync(_path, cancellation.Token));
    }

    [TestCase(false)]
    [TestCase(true)]
    public async Task MutationDuringAnIndividualReadIsUnstableAndLaterCompletedBytesAreReadable(bool sameLength)
    {
        await File.WriteAllTextAsync(_path, "first");
        DuringReadReader reader = new(() =>
        {
            DateTime timestamp = File.GetLastWriteTimeUtc(_path);
            File.WriteAllText(_path, sameLength ? "other" : "completed");
            File.SetLastWriteTimeUtc(_path, timestamp.AddSeconds(5));
        });
        SourceSnapshotException exception = Assert.ThrowsAsync<SourceSnapshotException>(() => reader.ReadAsync(_path))!;
        Assert.That(exception.Code, Is.EqualTo("source-changed-during-read"));
        SavedVariablesSnapshot stable = await new SavedVariablesSnapshotReader(quietPeriod: TimeSpan.Zero).ReadAsync(_path);
        Assert.That(stable.Content, Is.EqualTo(sameLength ? "other" : "completed"));
    }

    [Test]
    public void OversizeSourceIsRejectedBeforeAllocation()
    {
        using (FileStream stream = File.Create(_path))
            stream.SetLength(SavedVariablesSnapshotReader.MaximumSnapshotBytes + 1);
        SourceSnapshotException exception = Assert.ThrowsAsync<SourceSnapshotException>(() =>
            new SavedVariablesSnapshotReader(quietPeriod: TimeSpan.Zero).ReadAsync(_path))!;
        Assert.That(exception.Code, Is.EqualTo("source-too-large"));
    }

    private sealed class MutatingReader(Action mutate) : SavedVariablesSnapshotReader
    {
        protected override Task WaitForQuietAsync(CancellationToken cancellationToken)
        {
            mutate();
            return Task.CompletedTask;
        }
    }

    private sealed class DuringReadReader(Action mutate) : SavedVariablesSnapshotReader
    {
        protected override Stream OpenRead(string path) => new MutatingStream(base.OpenRead(path), mutate);
    }

    private sealed class MutatingStream(Stream inner, Action mutate) : Stream
    {
        private bool _mutated;
        public override bool CanRead => inner.CanRead;
        public override bool CanSeek => inner.CanSeek;
        public override bool CanWrite => false;
        public override long Length => inner.Length;
        public override long Position { get => inner.Position; set => inner.Position = value; }
        public override int Read(byte[] buffer, int offset, int count) => inner.Read(buffer, offset, count);
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            int read = await inner.ReadAsync(buffer, cancellationToken);
            if (!_mutated)
            {
                _mutated = true;
                mutate();
            }
            return read;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => inner.Seek(offset, origin);
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        protected override void Dispose(bool disposing)
        {
            if (disposing) inner.Dispose();
            base.Dispose(disposing);
        }
        public override async ValueTask DisposeAsync()
        {
            await inner.DisposeAsync();
            GC.SuppressFinalize(this);
        }
    }
}
