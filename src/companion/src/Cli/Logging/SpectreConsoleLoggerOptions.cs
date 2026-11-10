namespace ArtisanLogbook.Cli.Logging;

/// <summary>Presentation options; minimum levels and category filters use standard .NET logging configuration.</summary>
public sealed class SpectreConsoleLoggerOptions
{
    /// <summary>Show diagnostic messages, event identities, properties and detailed exceptions.</summary>
    public bool Verbose { get; set; }

    public bool IncludeScopes { get; set; }

    /// <summary>Disable styling even when the supplied console supports ANSI.</summary>
    public bool ForcePlainText { get; set; }
}
