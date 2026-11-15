using ArtisanLogbook.Runtime.GraphQL;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class RecordedConfigurationTests
{
    [Test]
    public void CoveredListsDistinguishMissingMalformedAndRecordedEmptyEvidence()
    {
        const string fields = """
            craftFields = {equipmentCoverage = "observed", buffsCoverage = "supported-list",
                finishingCoverage = "submitted", statsCoverage = "reported"}
            """;
        RecordedConfiguration missing = RecordedConfiguration.FromPayload(
            "CraftConfigurationEvidence = {" + fields + "}");
        RecordedConfiguration malformed = RecordedConfiguration.FromPayload(
            "CraftConfigurationEvidence = {conditions = {equipment = {[1] = \"unknown\"}, " +
            "buffs = \"unknown\", finishingReagents = {[2] = {itemID = 5}}, stats = \"unknown\"}, " + fields + "}");
        RecordedConfiguration empty = RecordedConfiguration.FromPayload(
            "CraftConfigurationEvidence = {conditions = {equipment = {}, buffs = {}, " +
            "finishingReagents = {}, stats = {}}, " + fields + "}");

        Assert.Multiple(() =>
        {
            Assert.That(missing.EquipmentCoverage, Is.EqualTo("observed"));
            Assert.That(missing.BuffsCoverage, Is.EqualTo("supported-list"));
            Assert.That(missing.FinishingCoverage, Is.EqualTo("submitted"));
            Assert.That(missing.Equipment, Is.Null);
            Assert.That(missing.Buffs, Is.Null);
            Assert.That(missing.FinishingReagents, Is.Null);
            Assert.That(missing.Statistics, Is.Null);
            Assert.That(malformed.Equipment, Is.Null);
            Assert.That(malformed.Buffs, Is.Null);
            Assert.That(malformed.FinishingReagents, Is.Null);
            Assert.That(malformed.Statistics, Is.Null);
            Assert.That(empty.Equipment, Is.Empty);
            Assert.That(empty.Buffs, Is.Empty);
            Assert.That(empty.FinishingReagents, Is.Empty);
            Assert.That(empty.Statistics, Is.Empty);
        });
    }
}
