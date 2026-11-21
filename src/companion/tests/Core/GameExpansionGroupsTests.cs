using ArtisanLogbook.History;

using NUnit.Framework;

namespace Tests.History;

[TestFixture]
public class GameExpansionGroupsTests
{
    private static readonly GameContext Retail = new(GameProject.Retail);

    // Skill lines and the expansion names a Retail 12.x client recorded for them in a real ledger.
    [TestCase(2477, "game:classic")]
    [TestCase(2548, "game:classic")]
    [TestCase(2484, "game:burning-crusade")]
    [TestCase(2476, "game:burning-crusade")]
    [TestCase(2483, "game:wrath")]
    [TestCase(2475, "game:wrath")]
    [TestCase(2482, "game:cataclysm")]
    [TestCase(2474, "game:cataclysm")]
    [TestCase(2481, "game:pandaria")]
    [TestCase(2473, "game:pandaria")]
    [TestCase(2480, "game:warlords")]
    [TestCase(2543, "game:warlords")]
    [TestCase(2479, "game:legion")]
    [TestCase(2542, "game:legion")]
    [TestCase(2478, "game:battle-for-azeroth")]
    [TestCase(2437, "game:battle-for-azeroth")]
    [TestCase(2541, "game:battle-for-azeroth")]
    [TestCase(2752, "game:shadowlands")]
    [TestCase(2822, "game:dragonflight")]
    [TestCase(2873, "game:war-within")]
    [TestCase(2908, "game:midnight")]
    public void ClientRecordedSkillLinesJoinTheirExpansion(int skillLine, string group)
    {
        string key = $"skillLine:{skillLine}";
        Assert.Multiple(() =>
        {
            Assert.That(GameExpansionGroups.GroupKey(Retail, key), Is.EqualTo(group));
            Assert.That(GameExpansionGroups.MemberKeys(Retail, group), Does.Contain(key));
        });
    }
}
