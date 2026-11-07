using System.ComponentModel;

using Spectre.Console;
using Spectre.Console.Cli;

namespace ArtisanLogbook.Cli.Commands;

public class DatabaseSettings : CommandSettings
{
    [CommandOption("--database <PATH>")]
    [Description("Override the shared history database path (relative to the working directory).")]
    public string? Database { get; init; }

    public override ValidationResult Validate() =>
        Database is not null && string.IsNullOrWhiteSpace(Database)
            ? ValidationResult.Error("--database must not be empty.")
            : base.Validate();
}
