using ArtisanLogbook.Cli;
using ArtisanLogbook.History;
using ArtisanLogbook.HistoryStore;
using ArtisanLogbook.ImportService;
using ArtisanLogbook.Runtime;
using ArtisanLogbook.SavedVariables;

using NUnit.Framework;

namespace Tests.Cli;

[TestFixture]
public sealed class ImportPresentationTests
{
    private static readonly CraftObservation Craft = new(new("sanitized-origin", "not-a-local-id"),
        new(GameProject.Retail), DateTimeOffset.FromUnixTimeSeconds(1800000000), null, new("sanitized-character"));

    [Test]
    public void DuplicateViewsDoNotDoubleCountButSeparateEqualOccurrencesArePreserved()
    {
        SavedVariablesDiagnostic warning = Warning("unknown-recipe");
        CompanionImportResult result = Result(CraftWriteStatus.Inserted, [warning, warning]) with
        {
            CoverageWarnings = [warning, warning]
        };
        ImportPresentation model = ImportReportingTests.Present(result);
        Assert.That(model.DiagnosticGroups.Single().Occurrences, Is.EqualTo(2));
        Assert.That(model.Sources.Single().Diagnostics, Has.Count.EqualTo(2));
        string verbose = ImportReportingTests.Render(model, true);
        Assert.That(verbose.Split("Warning (unknown-recipe)"), Has.Length.EqualTo(3));

        result = result with { CoverageWarnings = [warning, warning, warning] };
        Assert.That(ImportReportingTests.Present(result).DiagnosticGroups.Single().Occurrences, Is.EqualTo(3));
    }

    [TestCase(SavedVariablesDiagnosticScope.Unattributed, false)]
    [TestCase(SavedVariablesDiagnosticScope.Observation, false)]
    [TestCase(SavedVariablesDiagnosticScope.Observation, true)]
    public void UncertainAttributionStaysVisibleEvenWithOnlyExistingCrafts(SavedVariablesDiagnosticScope scope, bool missingIdentity)
    {
        SavedVariablesDiagnostic diagnostic = Warning("future-warning") with
        {
            Scope = scope,
            ObservationIdentity = missingIdentity ? null : new("different-origin", "not-a-local-id")
        };
        ImportPresentation model = ImportReportingTests.Present(Result(CraftWriteStatus.AlreadyPresent, [diagnostic]));
        Assert.That(model.Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
        Assert.That(ImportReportingTests.Render(model, false), Does.Contain(diagnostic.Message).And.Contain(diagnostic.Location));
    }

    [TestCase(CraftWriteStatus.Inserted, true)]
    [TestCase(CraftWriteStatus.Enriched, true)]
    [TestCase(CraftWriteStatus.AlreadyPresent, false)]
    public void LedgerWarningsFollowCommittedChanges(CraftWriteStatus status, bool visible)
    {
        SavedVariablesDiagnostic warning = Warning("legacy-identity-lineage") with
        {
            Scope = SavedVariablesDiagnosticScope.Ledger,
            ObservationIdentity = null
        };
        ImportPresentation model = ImportReportingTests.Present(Result(status, [warning]));
        Assert.That(model.Sources.Single().VisibleDiagnostics.Count, Is.EqualTo(visible ? 1 : 0));
    }

    [Test]
    public void LedgerWithNoRetainedObservationsCannotClaimPriorIngestionAndDimensionChangesAreVisible()
    {
        SavedVariablesDiagnostic warning = Warning("aggregate-only-history") with
        {
            Scope = SavedVariablesDiagnosticScope.Ledger,
            ObservationIdentity = null
        };
        CompanionImportResult result = Result(CraftWriteStatus.AlreadyPresent, [warning]);
        Assert.That(ImportReportingTests.Present(result with { TotalSourceCraftObservations = 0 })
            .Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
        Assert.That(ImportReportingTests.Present(result with { DimensionsEnriched = 1 })
            .Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
    }

    [TestCase("partial-output", true)]
    [TestCase("invalid-reagent-allocation", false)]
    [TestCase("historical-recipe-schematic-variation", false)]
    [TestCase("unknown-recipe", false)]
    [TestCase("future-warning", true)]
    public void OnlyRelevantKnownDiagnosticsAreShownForOutputEnrichment(string code, bool visible)
    {
        CompanionImportResult result = Result(CraftWriteStatus.Enriched, [Warning(code)]) with
        {
            Observations = [new(CraftWriteStatus.Enriched, Craft with { Outputs = [new(99, null, 1)] }, [], [])
                { PreviousObservation = Craft }]
        };
        Assert.That(ImportReportingTests.Present(result).Sources.Single().VisibleDiagnostics.Count,
            Is.EqualTo(visible ? 1 : 0));
    }

    [TestCase("historical-recipe-schematic-variation")]
    [TestCase("unknown-recipe-reagent-slot")]
    [TestCase("recipe-reagent-slot-without-recipe")]
    public void SchematicEnrichmentShowsRelevantDiagnostics(string code)
    {
        CompanionImportResult result = Result(CraftWriteStatus.Enriched, [Warning(code)]) with
        {
            Observations = [new(CraftWriteStatus.Enriched,
                Craft with { RecipeSchematicEvidence = [new("sanitized-source", "sanitized-payload")] }, [], [])
                { PreviousObservation = Craft }]
        };
        Assert.That(ImportReportingTests.Present(result).Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
    }

    [TestCase("invalid-reagent-item")]
    [TestCase("invalid-reagent-allocation")]
    [TestCase("invalid-reagent-return")]
    public void ReagentEnrichmentShowsRelevantDiagnostics(string code)
    {
        CompanionImportResult result = Result(CraftWriteStatus.Enriched, [Warning(code)]) with
        {
            Observations = [new(CraftWriteStatus.Enriched,
                Craft with { Reagents = [new(99, 1, null)] }, [], []) { PreviousObservation = Craft }]
        };
        Assert.That(ImportReportingTests.Present(result).Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
    }

    [Test]
    public void IncompleteReconciliationFactsAreConservativelyVisible()
    {
        CompanionImportResult result = Result(CraftWriteStatus.Enriched, [Warning("unknown-recipe")]) with
        {
            Observations = [new(CraftWriteStatus.Enriched, Craft, [], [])]
        };
        Assert.That(ImportReportingTests.Present(result).Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
        Assert.That(ImportReportingTests.Present(result with { Observations = [] })
            .Sources.Single().VisibleDiagnostics, Has.Count.EqualTo(1));
    }

    [TestCase("Outputs", "partial-output", false)]
    [TestCase("Reagents", "invalid-reagent-allocation", false)]
    [TestCase("OutputEvidence", "partial-output", true)]
    [TestCase("RecipeSchematicEvidence", "historical-recipe-schematic-variation", true)]
    public void EqualLengthCollectionsWithDifferentMultiplicitiesDoNotHideDiagnostics(
        string collection, string code, bool valid)
    {
        CraftOutput outputA = new(99, null, 1);
        CraftOutput outputB = new(100, null, 1);
        CraftReagent reagentA = new(99, 1, null);
        CraftReagent reagentB = new(100, 1, null);
        CraftOutputEvidence evidenceA = new("sanitized-source",
            [new(outputA, Craft.RecordedAt, new(), [])]);
        CraftOutputEvidence evidenceB = new("sanitized-source",
            [new(outputB, Craft.RecordedAt, new(), [])]);
        CraftRecipeSchematicEvidence schematicA = new("sanitized-source", "payload-a");
        CraftRecipeSchematicEvidence schematicB = new("sanitized-source", "payload-b");
        (CraftObservation before, CraftObservation after) = collection switch
        {
            "Outputs" => (Craft with { Outputs = [outputA, outputA, outputB] },
                Craft with { Outputs = [outputA, outputB, outputB] }),
            "Reagents" => (Craft with { Reagents = [reagentA, reagentA, reagentB] },
                Craft with { Reagents = [reagentA, reagentB, reagentB] }),
            "OutputEvidence" => (Craft with { OutputEvidence = [evidenceA, evidenceA, evidenceB] },
                Craft with { OutputEvidence = [evidenceA, evidenceB, evidenceB] }),
            "RecipeSchematicEvidence" => (Craft with { RecipeSchematicEvidence = [schematicA, schematicA, schematicB] },
                Craft with { RecipeSchematicEvidence = [schematicA, schematicB, schematicB] }),
            _ => throw new ArgumentOutOfRangeException(nameof(collection))
        };
        Assert.That(HistoryValidator.Validate([before]).Count == 0, Is.EqualTo(valid));
        Assert.That(HistoryValidator.Validate([after]).Count == 0, Is.EqualTo(valid));
        if (!valid)
        {
            Assert.That(before, Is.Not.EqualTo(after), "C01 canonical equality preserves row multiplicity.");
            Assert.That(HistoryValidator.Validate([before]).Single().Field, Is.EqualTo(collection),
                "Duplicate canonical grains cannot reach a successful C03 commit.");
        }
        AssertEnrichmentVisibility(before, after, code, true);
    }

    [TestCase("Outputs", "partial-output", false)]
    [TestCase("Reagents", "invalid-reagent-allocation", false)]
    [TestCase("OutputEvidence", "partial-output", true)]
    [TestCase("RecipeSchematicEvidence", "historical-recipe-schematic-variation", true)]
    public void CollectionOrderingMatchesCanonicalRowsAndPersistedEvidence(
        string collection, string code, bool visible)
    {
        CraftOutput outputA = new(99, null, 1);
        CraftOutput outputB = new(100, null, 1);
        CraftReagent reagentA = new(99, 1, null);
        CraftReagent reagentB = new(100, 1, null);
        CraftOutputEvidence evidenceA = new("sanitized-source",
            [new(outputA, Craft.RecordedAt, new(), [])]);
        CraftOutputEvidence evidenceB = new("sanitized-source",
            [new(outputB, Craft.RecordedAt, new(), [])]);
        CraftRecipeSchematicEvidence schematicA = new("sanitized-source", "payload-a");
        CraftRecipeSchematicEvidence schematicB = new("sanitized-source", "payload-b");
        (CraftObservation before, CraftObservation after) = collection switch
        {
            "Outputs" => (Craft with { Outputs = [outputA, outputB] }, Craft with { Outputs = [outputB, outputA] }),
            "Reagents" => (Craft with { Reagents = [reagentA, reagentB] }, Craft with { Reagents = [reagentB, reagentA] }),
            "OutputEvidence" => (Craft with { OutputEvidence = [evidenceA, evidenceB] },
                Craft with { OutputEvidence = [evidenceB, evidenceA] }),
            "RecipeSchematicEvidence" => (Craft with { RecipeSchematicEvidence = [schematicA, schematicB] },
                Craft with { RecipeSchematicEvidence = [schematicB, schematicA] }),
            _ => throw new ArgumentOutOfRangeException(nameof(collection))
        };
        Assert.That(HistoryValidator.Validate([before]), Is.Empty);
        Assert.That(HistoryValidator.Validate([after]), Is.Empty);
        AssertEnrichmentVisibility(before, after, code, visible);
    }

    [Test]
    public void OutputEvidenceComparisonPreservesCallbackOrderAndMultiplicity()
    {
        CraftOutputObservation callbackA = new(new(99, null, 1), Craft.RecordedAt, new(), []);
        CraftOutputObservation callbackB = new(new(100, null, 1), Craft.RecordedAt, new(), []);
        CraftOutputEvidence evidence = new("sanitized-source", [callbackA, callbackA, callbackB]);
        CraftObservation before = Craft with { OutputEvidence = [evidence] };
        foreach (IReadOnlyList<CraftOutputObservation> callbacks in new IReadOnlyList<CraftOutputObservation>[]
        {
            [callbackA, callbackB, callbackB], [callbackA, callbackB, callbackA]
        })
        {
            CraftObservation after = Craft with { OutputEvidence = [evidence with { Callbacks = callbacks }] };
            Assert.That(HistoryValidator.Validate([after]), Is.Empty);
            AssertEnrichmentVisibility(before, after, "partial-output", true);
        }
        AssertEnrichmentVisibility(before, Craft with
        {
            OutputEvidence = [evidence with
            { Callbacks = evidence.Callbacks.ToArray() }]
        }, "partial-output", false);
    }

    [TestCase("partial-output")]
    [TestCase("invalid-reagent-allocation")]
    [TestCase("historical-recipe-schematic-variation")]
    public void UnknownAndObservedEmptyCollectionsRemainDistinct(string code)
    {
        CraftObservation after = code switch
        {
            "partial-output" => Craft with { Outputs = [] },
            "invalid-reagent-allocation" => Craft with { Reagents = [] },
            _ => Craft with { RecipeSchematicEvidence = [] }
        };
        AssertEnrichmentVisibility(Craft, after, code, true);
        AssertEnrichmentVisibility(Craft, Craft, code, false);
        AssertEnrichmentVisibility(after, after, code, false);
    }

    private static void AssertEnrichmentVisibility(
        CraftObservation before, CraftObservation after, string code, bool visible)
    {
        CompanionImportResult result = Result(CraftWriteStatus.Enriched, [Warning(code)]) with
        {
            Observations = [new(CraftWriteStatus.Enriched, after, [], []) { PreviousObservation = before }]
        };
        ImportSourcePresentation source = ImportReportingTests.Present(result).Sources.Single();
        Assert.That(source.VisibleDiagnostics.Count, Is.EqualTo(visible ? 1 : 0));
        Assert.That(source.Diagnostics.Single().ObservationIdentity, Is.EqualTo(after.Identity));
    }

    [Test]
    public void ErrorConflictAndValidationDetailsRemainVisibleAndAreNotGroupedWithWarnings()
    {
        SavedVariablesDiagnostic warning = Warning("unknown-recipe");
        CompanionImportResult result = Result(CraftWriteStatus.AlreadyPresent, [warning,
            warning with { Severity = SavedVariablesDiagnosticSeverity.Error, Code = "source-validation-error" }]) with
        {
            Outcome = CompanionImportOutcome.Rejected,
            ValidationErrors = [new(Craft.Identity, "RecipeId", "validation detail")],
            CraftConflicts = [new(Craft.Identity, "Outputs", "craft conflict detail")],
            DimensionConflicts = [new("Recipe", "77", "dimension conflict detail")]
        };
        foreach (bool verbose in new[] { false, true })
        {
            ImportPresentation model = ImportReportingTests.Present(result);
            string output = ImportReportingTests.Render(model, verbose);
            Assert.That(model.ExitCode, Is.EqualTo(ExitCodes.Rejected));
            Assert.That(output, Does.Contain("source-validation-error").And.Contain("validation detail")
                .And.Contain("craft conflict detail").And.Contain("dimension conflict detail")
                .And.Contain("sanitized-origin").And.Contain("not-a-local-id").And.Contain("77"));
        }
    }

    [Test]
    public void GroupsKeepSeveritySeparateAndSuppressedOccurrenceCountsAreExact()
    {
        SavedVariablesDiagnostic warning = Warning("unknown-recipe");
        CompanionImportResult result = Result(CraftWriteStatus.Inserted,
            [warning, warning with { Severity = SavedVariablesDiagnosticSeverity.Information }]);
        ImportPresentation model = ImportReportingTests.Present(result);
        Assert.That(model.DiagnosticGroups, Has.Count.EqualTo(2));
        Assert.That(model.DiagnosticGroups.All(group => group.Occurrences == 1), Is.True);
        model = ImportReportingTests.Present(Result(CraftWriteStatus.AlreadyPresent, [warning, warning]));
        Assert.That(model.Sources.Single().SuppressedDiagnostics, Has.Count.EqualTo(2));
        Assert.That(model.DiagnosticGroups, Is.Empty);
    }

    private static SavedVariablesDiagnostic Warning(string code) =>
        new(SavedVariablesDiagnosticSeverity.Warning, code, "opaque-location-no-id", "original diagnostic message")
        { Scope = SavedVariablesDiagnosticScope.Observation, ObservationIdentity = Craft.Identity };

    private static CompanionImportResult Result(CraftWriteStatus status, IReadOnlyList<SavedVariablesDiagnostic> diagnostics) =>
        new(CompanionImportOutcome.Successful, 1,
            status == CraftWriteStatus.Inserted ? 1 : 0,
            status == CraftWriteStatus.AlreadyPresent ? 1 : 0,
            status == CraftWriteStatus.Enriched ? 1 : 0,
            0, 0, 0, null, diagnostics, diagnostics, [], [], [], [], [])
        { Observations = [new(status, Craft, [], []) { PreviousObservation = status == CraftWriteStatus.Enriched ? Craft : null }] };
}
