using ArtisanLogbook.ImportService;

namespace ArtisanLogbook.Runtime;

/// <summary>Runtime request admission around C07. Manual CLI imports continue calling C07 directly.</summary>
public class CompanionRuntimeImports(CompanionWorkAdmission admission, CompanionImportService importer)
{
    public virtual async Task<CompanionImportResult> ImportSavedVariablesAsync(
        string content, string sourceName = "<memory>", CancellationToken cancellationToken = default)
    {
        using IDisposable lease = admission.Admit();
        return await importer.ImportSavedVariablesAsync(content, sourceName, cancellationToken);
    }

    public virtual async Task<CompanionImportResult> ImportSavedVariablesFileAsync(
        string path, CancellationToken cancellationToken = default)
    {
        using IDisposable lease = admission.Admit();
        return await importer.ImportSavedVariablesFileAsync(path, cancellationToken);
    }
}
