using System.Data.Common;

using DuckDB.NET.Data;

namespace ArtisanLogbook.HistoryStore;

public sealed partial class HistoryStore
{
    private static ReadOnlySpan<byte> DuckDbMagic => "DUCK"u8;
    private const int SharingViolation = 32;
    private const int LockViolation = 33;

    /// <summary>
    /// Permanently deletes a history database file and its write-ahead log.
    /// The file must be a DuckDB database (any schema version, including
    /// unsupported ones) that no other process currently holds open for writing.
    /// </summary>
    /// <returns><see langword="false"/> when no database file exists.</returns>
    public static bool Erase(string databasePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        string path = Path.GetFullPath(databasePath);
        if (Directory.Exists(path))
            throw new IOException("The database path is a directory; specify --database <file>.");
        if (!File.Exists(path))
            return false;

        try
        {
            EnsureDuckDbFile(path);
        }
        catch (IOException exception) when ((exception.HResult & 0xFFFF) is SharingViolation or LockViolation)
        {
            throw new IOException(
                "The history database is in use by another process and was not erased. " +
                "If the database is locked, close other Companion/DuckDB processes using it and retry.", exception);
        }

        // Opening for writing acquires DuckDB's file lock, so a database in use
        // by another Companion or DuckDB process fails here and stays intact.
        DbConnectionStringBuilder connectionString = new() { ["Data Source"] = path };
        using (DuckDBConnection connection = new(connectionString.ConnectionString))
            connection.Open();

        File.Delete(path);
        File.Delete(path + ".wal");
        return true;
    }

    private static void EnsureDuckDbFile(string path)
    {
        using FileStream stream = new(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (stream.Length == 0)
            return;
        Span<byte> header = stackalloc byte[12];
        if (stream.ReadAtLeast(header, header.Length, throwOnEndOfStream: false) < header.Length ||
            !header[8..].SequenceEqual(DuckDbMagic))
            throw new InvalidDataException(
                "The path is not a DuckDB history database; nothing was erased.");
    }
}
