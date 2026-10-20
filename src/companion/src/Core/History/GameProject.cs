namespace ArtisanLogbook.History;

/// <summary>
/// Blizzard WOW_PROJECT_ID. Numeric values outside these named members are valid:
/// a future client can be represented without updating this library.
/// This identifies the game project, not the expansion, season, or API family.
/// </summary>
public enum GameProject
{
    Retail = 1,
    ClassicEra = 2,
    WowLabs = 3,
    BurningCrusadeClassic = 5,
    WrathClassic = 11,
    CataclysmClassic = 14,
    Forever = 18,
    MistsClassic = 19
}
