using System.Security.Cryptography;
using System.Text;

namespace ArtisanLogbook.History;

/// <summary>
/// Identity assigned to an individual craft observation by its origin.
/// The origin must remain stable across copies of the same history.
/// </summary>
/// <remarks>
/// A legacy SavedVariables local craft ID alone is NOT globally unique.
/// Adapters must not invent distinct origins for cloned ledgers and silently
/// treat coincident local IDs as unrelated crafts.
/// </remarks>
public sealed record CraftIdentity
{
    public string Origin { get; }
    public string Observation { get; }

    public CraftIdentity(string origin, string observation)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(origin);
        ArgumentException.ThrowIfNullOrWhiteSpace(observation);

        Origin = origin;
        Observation = observation;
    }

    /// <summary>
    /// A short public identifier derived from the identity: the first 16 lower-case hex digits of the SHA-256 of
    /// origin and observation. Being derived, it is the same after a reimport and on every machine.
    /// </summary>
    public string ShortId => CraftShortIds.Of(Origin, Observation);
}

/// <summary>Derivation and validation of craft short IDs.</summary>
public static class CraftShortIds
{
    public const int Length = 16;

    public static string Of(string origin, string observation)
    {
        // Length-prefixing the origin keeps distinct (origin, observation) pairs from concatenating alike.
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{origin.Length}:{origin}{observation}"));
        return Convert.ToHexString(hash, 0, Length / 2).ToLowerInvariant();
    }

    public static bool IsValid(string? value) =>
        value is { Length: Length } && value.All(c => char.IsAsciiDigit(c) || c is >= 'a' and <= 'f');
}
