using Microsoft.Extensions.FileProviders;

namespace ArtisanLogbook.WebAssets;

public static class EmbeddedFrontend
{
    public static IFileProvider CreateFileProvider()
    {
#if COMPANION_WEB_DEVELOPMENT
        return new NullFileProvider();
#else
        return new ManifestEmbeddedFileProvider(typeof(EmbeddedFrontend).Assembly, "wwwroot");
#endif
    }
}
