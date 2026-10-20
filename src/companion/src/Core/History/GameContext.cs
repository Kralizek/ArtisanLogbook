namespace ArtisanLogbook.History;

/// <summary>Identity of a game environment. A progression track distinguishes realm families sharing a client.</summary>
public sealed record GameContext
{
    public GameProject Project { get; }
    public string? ProgressionTrack { get; }

    public GameContext(GameProject project, string? progressionTrack = null)
    {
        if ((int)project <= 0)
            throw new ArgumentOutOfRangeException(nameof(project), "A game project must be a positive Blizzard project ID.");
        if (progressionTrack is not null && string.IsNullOrWhiteSpace(progressionTrack))
            throw new ArgumentException("Progression track cannot be blank.", nameof(progressionTrack));
        Project = project;
        ProgressionTrack = progressionTrack;
    }
}
