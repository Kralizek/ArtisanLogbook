using System.Globalization;
using System.Text;

using ArtisanLogbook.History;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

namespace Tests.SavedVariables;

// Synthetic reproduction of issue #84: a Forever ledger whose late sessions fell back to
// session-scoped realm/character dimensions while a stable identity for the same GUID exists.
[TestFixture]
public class SessionCharacterLineageTests
{
    private const string Guid = "Player-6941-0SANITIZED";
    private const string StableKey = "project:18:region:3:realm:6941:guid:" + Guid;

    [Test]
    public void SessionScopedDuplicatesOfAStableGuidRecoverTheStableIdentity()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse(Ledger());

        Assert.That(result.IsSuccessful, Is.True, string.Join(Environment.NewLine, result.Diagnostics));
        Assert.That(result.History!.Crafts, Has.Count.EqualTo(31));
        Assert.That(result.History.Crafts.Select(c => c.Character.Key).Distinct(), Is.EqualTo(new[] { StableKey }));
        Assert.That(result.History.Dimensions.Characters.Select(c => c.Identity.Key), Is.EqualTo(new[] { StableKey }));
        SavedVariablesDiagnostic[] recovered = result.Diagnostics
            .Where(d => d.Code == "character-identity-recovered").ToArray();
        Assert.That(recovered.Select(d => d.Location), Is.EquivalentTo(new[]
        {
            "ArtisanLogbookDB.dimensions.characters[id=3]", "ArtisanLogbookDB.dimensions.characters[id=4]"
        }));
        Assert.That(recovered.All(d => d.Severity == SavedVariablesDiagnosticSeverity.Information &&
            !d.Message.Contains(Guid, StringComparison.Ordinal)), Is.True);
    }

    [Test]
    public void RecoveredImportIsIdempotent()
    {
        SavedVariablesImportResult first = SavedVariablesReader.Parse(Ledger());
        SavedVariablesImportResult second = SavedVariablesReader.Parse(Ledger());
        CraftHistoryMergeResult merge = CraftHistoryReconciler.Merge(first.History!, second.History!);

        Assert.That(merge.IsSuccessful, Is.True);
        Assert.That(merge.History!.Crafts, Is.EquivalentTo(first.History!.Crafts));
        Assert.That(merge.History.Dimensions.Characters, Has.Count.EqualTo(1));
    }

    [Test]
    public void UnknownGuidWithoutRealmIdentityRemainsRejectedWithContext()
    {
        SavedVariablesImportResult result = SavedVariablesReader.Parse(Ledger(sessionGuid: "Player-6941-0OTHER"));

        AssertRejected(result, "no stable character with the same GUID");
        SavedVariablesDiagnostic error = result.Diagnostics.First(d => d.Code == "unknown-character-identity");
        Assert.That(error.Message, Does.Contain("Session 40, character dimension 3, realm unresolved:session:40"));
        Assert.That(error.Message, Does.Not.Contain("Player-6941"));
        Assert.That(result.History!.Crafts.Select(c => c.Character.Key).Distinct(), Is.EqualTo(new[] { StableKey }));
    }

    [Test]
    public void DifferentRegionIsNotMerged() =>
        AssertRejected(SavedVariablesReader.Parse(Ledger(unresolvedRegion: 1)), "different region");

    [Test]
    public void MissingRegionIsNotMerged() =>
        AssertRejected(SavedVariablesReader.Parse(Ledger(unresolvedRegion: null)), "has no region");

    [Test]
    public void DifferentClassIsNotMerged() =>
        AssertRejected(SavedVariablesReader.Parse(Ledger(sessionClass: "MAGE")), "different class");

    [Test]
    public void DifferentRealmNameIsNotMerged() =>
        AssertRejected(SavedVariablesReader.Parse(Ledger(unresolvedRealmName: "Another Realm")), "different realm name");

    [Test]
    public void AmbiguousStableClaimsAreNotMerged()
    {
        string extra = $$"""{ id = 5, name = "Crafter", classFile = "DRUID", guid = "{{Guid}}", realmDimensionId = 4, key = "project:18:region:3:realm:7000:guid:{{Guid}}" },""";
        string extraRealm = """{ id = 4, identityScope = "runtime", projectId = 18, regionId = 3, gameRealmId = 7000, name = "Other Realm", key = "project:18:region:3:realm:7000" },""";
        AssertRejected(SavedVariablesReader.Parse(Ledger(extraCharacters: extra, extraRealms: extraRealm)),
            "several stable identities");
    }

    [Test]
    public void StableClaimFromAnotherProjectIsNotMerged() =>
        AssertRejected(SavedVariablesReader.Parse(Ledger(stableProject: 1)), "no stable character with the same GUID");

    private static void AssertRejected(SavedVariablesImportResult result, string reason)
    {
        SavedVariablesDiagnostic[] errors = result.Diagnostics.Where(d => d.Code == "unknown-character-identity").ToArray();
        Assert.That(result.IsSuccessful, Is.False);
        Assert.That(errors, Has.Length.EqualTo(30));
        Assert.That(errors.All(d => d.Message.Contains(reason, StringComparison.Ordinal)), Is.True,
            string.Join(Environment.NewLine, errors.Select(d => d.Message).Distinct()));
        Assert.That(result.Diagnostics.Any(d => d.Code == "character-identity-recovered"), Is.False);
    }

    private static string Ledger(string sessionGuid = Guid, int? unresolvedRegion = 3, string sessionClass = "DRUID",
        string unresolvedRealmName = "", int stableProject = 18, string extraCharacters = "", string extraRealms = "")
    {
        string region = unresolvedRegion is int r ? $"regionId = {r}," : "";
        StringBuilder crafts = new();
        crafts.AppendLine("{ id = 286, sessionId = 39, timestamp = 1795215000, recipeId = 7836 },");
        for (int id = 287; id <= 316; id++)
            crafts.AppendLine(CultureInfo.InvariantCulture,
                $"{{ id = {id}, sessionId = {(id == 316 ? 41 : 40)}, timestamp = {1795215028 + id}, recipeId = {(id == 316 ? 3278 : 7836)} }},");
        return $$"""
            ArtisanLogbookDB = {
              schemaVersion = 5, schemaIdentity = "ArtisanLogbookLedger",
              crafts = { {{crafts}} },
              dimensions = {
                sessions = {
                  { id = 39, key = "session-39", projectId = 18, characterDimensionId = 2, realmDimensionId = 1 },
                  { id = 40, key = "session-40", projectId = 18, characterDimensionId = 3, realmDimensionId = 2 },
                  { id = 41, key = "session-41", projectId = 18, characterDimensionId = 4, realmDimensionId = 3 }
                },
                realms = {
                  { id = 1, identityScope = "runtime", projectId = {{stableProject}}, regionId = 3, gameRealmId = 6941,
                    name = "Sanitized Realm", key = "project:{{stableProject}}:region:3:realm:6941" },
                  { id = 2, identityScope = "session", projectId = 18, {{region}} name = "{{unresolvedRealmName}}", key = "unresolved:session:40" },
                  { id = 3, identityScope = "session", projectId = 18, {{region}} name = "{{unresolvedRealmName}}", key = "unresolved:session:41" },
                  {{extraRealms}}
                },
                characters = {
                  { id = 2, name = "Crafter", classFile = "DRUID", guid = "{{Guid}}", realmDimensionId = 1,
                    key = "project:{{stableProject}}:region:3:realm:6941:guid:{{Guid}}" },
                  { id = 3, name = "Crafter", classFile = "{{sessionClass}}", guid = "{{sessionGuid}}", realmDimensionId = 2,
                    key = "unresolved:session:40:guid:{{sessionGuid}}" },
                  { id = 4, name = "Crafter", classFile = "{{sessionClass}}", guid = "{{sessionGuid}}", realmDimensionId = 3,
                    key = "unresolved:session:41:guid:{{sessionGuid}}" },
                  {{extraCharacters}}
                },
                recipes = { [7836] = { id = 7836 }, [3278] = { id = 3278 } }
              }
            }
            """;
    }
}
