using ArtisanLogbook.Cli;

using Spectre.Console;

return await CompanionCommandApp.Create(AnsiConsole.Console, ApplicationPaths.ForCurrentUser()).RunAsync(args);
