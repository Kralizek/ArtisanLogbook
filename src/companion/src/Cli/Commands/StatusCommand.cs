using System.Globalization;

using ArtisanLogbook.HistoryStore;

using Spectre.Console;
using Spectre.Console.Cli;

using Store = ArtisanLogbook.HistoryStore.HistoryStore;

namespace ArtisanLogbook.Cli.Commands;

public sealed class StatusCommand(ApplicationPaths paths, IAnsiConsole console) : Command<DatabaseSettings>
{
    public override int Execute(CommandContext context, DatabaseSettings settings)
    {
        string database = paths.ResolveDatabase(settings.Database);
        console.WriteLine($"Database: {database}");
        try
        {
            if (File.GetAttributes(database).HasFlag(FileAttributes.Directory))
                throw new IOException("The database path is a directory; specify --database <file>.");
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            console.MarkupLine("[yellow]Database does not exist. Import a snapshot to create it.[/]");
            return ExitCodes.Success;
        }

        console.WriteLine("Database exists. Opening read-only.");
        using Store store = new(database, readOnly: true);
        HistoryStoreStatus status = store.ReadStatus();
        console.MarkupLine("[green]History status (read-only).[/]");
        Table summary = new Table().AddColumn("History").AddColumn("Value");
        summary.AddRow("Schema version", status.SchemaVersion.ToString(CultureInfo.InvariantCulture));
        summary.AddRow("Canonical crafts", status.TotalCraftCount.ToString(CultureInfo.InvariantCulture));
        summary.AddRow("Oldest craft (UTC)", FormatTimestamp(status.OldestCraft));
        summary.AddRow("Newest craft (UTC)", FormatTimestamp(status.NewestCraft));
        console.Write(summary);

        Table contexts = new Table().AddColumn("GameContext").AddColumn("Project ID")
            .AddColumn("Progression track").AddColumn("Crafts");
        foreach (GameContextCraftCount count in status.Contexts)
            contexts.AddRow(Markup.Escape(count.Game.Project.ToString()),
                ((int)count.Game.Project).ToString(CultureInfo.InvariantCulture),
                Markup.Escape(count.Game.ProgressionTrack ?? "(unspecified)"),
                count.CraftCount.ToString(CultureInfo.InvariantCulture));
        console.Write(contexts);
        return ExitCodes.Success;
    }

    private static string FormatTimestamp(DateTimeOffset? timestamp) =>
        timestamp?.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss.ffffff", CultureInfo.InvariantCulture) ?? "(none)";
}
