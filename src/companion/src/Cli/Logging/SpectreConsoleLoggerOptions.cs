namespace ArtisanLogbook.Cli.Logging;

/// <summary>Presentation options; minimum levels and category filters use standard .NET logging configuration.</summary>
public sealed class SpectreConsoleLoggerOptions
{
    public bool IncludeScopes { get; set; }

    /// <summary>Disable styling even when the supplied console supports ANSI.</summary>
    public bool ForcePlainText { get; set; }
}
