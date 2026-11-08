using ArtisanLogbook.Cli;
using ArtisanLogbook.Runtime;

using Spectre.Console;

return await CompanionCommandApp.Create(AnsiConsole.Console, ApplicationPaths.ForCurrentUser()).RunAsync(args);
