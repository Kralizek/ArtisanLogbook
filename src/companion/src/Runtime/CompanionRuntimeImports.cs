using ArtisanLogbook.ImportService;

namespace ArtisanLogbook.Runtime;

/// <summary>Runtime request admission around C07. Manual CLI imports continue calling C07 directly.</summary>
public sealed class CompanionRuntimeImports(CompanionWorkAdmission admission, CompanionImportService importer)
{
    public async Task<CompanionImportResult> ImportSavedVariablesAsync(
        string content, string sourceName = "<memory>", CancellationToken cancellationToken = default)
    {
        using IDisposable lease = admission.Admit();
        return await importer.ImportSavedVariablesAsync(content, sourceName, cancellationToken);
    }

    public async Task<CompanionImportResult> ImportSavedVariablesFileAsync(
        string path, CancellationToken cancellationToken = default)
    {
        using IDisposable lease = admission.Admit();
        return await importer.ImportSavedVariablesFileAsync(path, cancellationToken);
    }
}
