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
}
