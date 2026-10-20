# SavedVariables adapter

`ArtisanLogbook.Companion.SavedVariables` is the C04 boundary between the addon's SavedVariables data and Core craft history. It only parses/serializes in-memory text; it does not read or replace files, monitor WoW, orchestrate imports, persist history, or merge aggregate snapshots.

## Source format evidence

The adapter was grounded in the addon's actual storage implementation:

- [`Ledger.lua`](../../../addon/src/ArtisanLogbook_Core/Storage/Ledger.lua) defines `ArtisanLogbookLedger`, the current schema version (4), migrations from schema versions 1–3, validation, retention pruning, dimensions, craft/request/reagent facts, and rollups.
- [`Bootstrap.lua`](../../../addon/src/ArtisanLogbook_Core/Core/Bootstrap.lua) creates a session with the WoW `WOW_PROJECT_ID`, realm IDs, and character GUID. Each craft references its session.
- [`Trace.lua`](../../../addon/src/ArtisanLogbook_Core/Capture/Trace.lua) documents the addon's data-only Lua literal serialization conventions.
- Sanitized, repository-maintained schema-1 snapshots [`v1-outcome1.lua`](../../../addon/tests/fixtures/legacy/v1-outcome1.lua) and [`v1-outcome2.lua`](../../../addon/tests/fixtures/legacy/v1-outcome2.lua), plus the schema-3 snapshot [`ledger-schema3.lua`](../../../addon/tests/fixtures/legacy/ledger-schema3.lua), exercise legacy ledger shapes and recovery/pruning behavior. The repository does not contain an anonymized export from a live WoW installation; these fixtures are test-generated historical ledger snapshots, not a claim of production-user capture coverage.

### Relationships and authority

| Source | Meaning | Canonical treatment |
|---|---|---|
| `crafts[].id` | Ledger-local craft row identity | Local provenance only; never globally unique by itself |
| `crafts[].sessionId` → `dimensions.sessions[]` | Craft's session | Required source of `projectId`; missing/invalid context is an error |
| session `characterDimensionId` → `dimensions.characters[]` | Character | Requires stable `project/region/realm/GUID` identity |
| session `realmDimensionId` → `dimensions.realms[]` | Realm metadata | Cross-checks project and can establish a missing stable character key with a GUID |
| `crafts[].requestId` → `requests[]` | Submission/session correlation | Preserved as provenance; request allocations supply input evidence only when craft reagent facts are absent |
| `crafts[].recipeId` → `dimensions.recipes` | Recipe identity | A recovered recipe is authoritative when persisted by Core; absent recipe remains unknown |
| recipe `professionId` → `dimensions.professions` | Profession classification | Optional numeric skill-line dimension |
| recipe `expansionDimensionId` → `dimensions.expansions` | Addon expansion dimension | Only a stable `skillLine:<id>` key is exposed as the canonical profession expansion |
| `crafts[].outputItemId`, `outputQuantity`, `outputQuality` | Observed output | Mapped to the craft × item × quality grain |
| `reagents[]` → craft and item IDs | Per-craft allocated/returned materials | Duplicate slots fold to craft × item; allocation and return stay independently nullable |
| `craftSeries`, `reagentSeries`, `resourcefulnessSets`, other `*Series` | Derived historical rollups | Used only to detect aggregate-only coverage; never turned into craft facts |
| session version/build/capabilities, `configurations` | Operational metadata | Not mapped to craft history; existing target configuration rows are retained when supplied |

The recorder's `outcomeSource`, `hasResourcefulnessProc`, and `resourcefulnessComplete` are separate evidence. Missing `returnedQuantity` remains unknown, while an explicit zero remains zero. Core dimensions are scoped by game context, including repeated item, recipe, and profession IDs.

## Lua subset and API

`LuaDataParser` accepts only:

- top-level `ArtisanLogbookDB = { ... }`/other global assignments or one `return { ... }`;
- nested table constructors, implicit sequence entries, identifier fields, numeric/string/boolean keys, finite numbers, booleans, `nil`, quoted strings and Lua short-string escapes;
- line comments and `--[[...]]` comments.

It never evaluates Lua. Calls, functions, operators, metatables, long strings, and arbitrary expressions are rejected with source line/column diagnostics. Input size, nesting, and table-entry limits are bounded.

```csharp
using ArtisanLogbook.SavedVariables;

SavedVariablesImportResult parsed = SavedVariablesReader.Parse(savedVariablesText, "snapshot.lua");
if (!parsed.IsSuccessful)
    throw new InvalidDataException(string.Join(Environment.NewLine, parsed.Diagnostics));

CraftHistory history = parsed.History!;
SavedVariablesWriteResult exported = SavedVariablesWriter.Serialize(
    history,
    existingTargetState: targetSnapshot,
    options: new SavedVariablesWriteOptions(
        Now: DateTimeOffset.UtcNow,
        GameContext: new GameContext(GameProject.Retail),
        SourceCoverage: parsed.Coverage));
if (!exported.IsSuccessful)
    throw new InvalidDataException(string.Join(Environment.NewLine, exported.Diagnostics));

string convertedText = exported.Content!;
```

`SavedVariablesReader.Parse` supports ledger schema versions 1–4. It interprets their persisted craft facts directly; it does not run the addon's Lua migrations or apply retention pruning. Malformed schema/layout, unknown project, conflicting project references, unstable character identity, and unsupported schema versions are reported explicitly. Individual crafts with unestablished required identity/context are not promoted.

The current source supplies `projectId` on each session, but has no trusted progression-track field. The adapter reads a `companionProgressionTrack` session extension only when it was explicitly serialized by this adapter; it never infers a track from the build, version, date, or profession expansion. Existing ledgers without `projectId` cannot be safely classified.

## Identity and reconciliation

For legacy input, the deterministic Core origin uses the project, stable character key, and persisted session key; the observation uses the ledger-local craft ID. This is replay-stable for the same ledger snapshot, and the original operation/request/session values remain in `CraftProvenance`. The adapter emits a `legacy-identity-lineage` warning because the addon's current format has no durable source-ledger lineage. Copies that diverged while reusing a session/local craft ID can be indistinguishable from one craft with conflicting facts—or from distinct crafts with identical facts. The adapter does not guess; use [`CraftHistoryReconciler`](../Core/History/CraftHistoryReconciler.cs) to surface known collisions.

Minimal addon follow-up: persist a durable ledger lineage ID and a source-assigned craft observation ID that survives file copies, and define how a copied ledger changes lineage when independent recording begins. Add a first-class progression-track value only where the game supplies trustworthy project/track evidence. Until then, legacy ambiguity remains a documented limitation; see [#51](https://github.com/Kralizek/ArtisanLogbook/issues/51) for the focused recorder-lineage follow-up.

Recipe/item IDs remain Blizzard numeric IDs scoped by `GameContext`. Recovered recipe IDs are accepted only when the source has recorded them (or when rows were deliberately grouped by this adapter's companion metadata). No recipe fingerprints, content-era namespaces, catalog integration, GUID identities, or cross-game equivalence are introduced.

## Serialization, rollups, and limitations

The writer emits a complete schema-4 `ArtisanLogbookDB` assignment with collision-free local craft, session, character, and expansion IDs and consistent references. A single output row per item/quality is emitted for multi-output observations; companion grouping metadata lets the reader restore one canonical observation. Adapter-only metadata is namespaced `companion*`; the addon's loader validation was exercised against generated output.

Detailed craft/reagent rows are limited to `RetentionDays` (default 60); `craftSeries`, `reagentSeries`, and `resourcefulnessSets` are regenerated from every craft observation supplied, including older observations. If the source contained rollup-only/pruned periods, the reader reports them and the writer carries that coverage warning forward when `SourceCoverage` is supplied. It does not fabricate crafts.

The following limits are intentional:

- A SavedVariables ledger represents one selected `GameContext`; exporting several contexts requires one conversion per context. The writer rejects implicit multi-context selection.
- The Core model does not contain historical recipe input requirements, first-craft reward observations, quote/configuration snapshots, or every request's operational intent. Those are not recreated as craft facts. First-craft reward rollups are cleared; `reagentRequirementSeries` is empty because no canonical per-craft requirement fact exists. Existing trace assignments and unrelated top-level Lua assignments are retained.
- Detailed `InputsComplete` and Resourcefulness completeness/source evidence use companion metadata if the old addon's native field requires request state absent from the canonical craft model. The addon's native `requests` array is not reconstructed with guessed `useConcentration` or requested counts.
- The addon's schema has one primary output per persisted craft row. The writer uses several compatible rows for a canonical multi-output craft and emits grouping metadata; imported rows without this metadata remain separate source craft records.
- Fractional legacy returned-material measurements are preserved as `decimal` in Core; Lua's numeric runtime remains IEEE-754, so exactness is limited by the source/runtime numeric representation.
- The repository has sanitized historical and synthetic cases, not a live installation export. A sanitized current schema-4 capture should be added once the project can provide one without exposing personal character data.

No output is written to the filesystem. Callers remain responsible for choosing where returned text goes; this library never replaces a live SavedVariables file.

## Tests

From `src/companion`:

```sh
dotnet test tests/SavedVariables/Tests.SavedVariables.csproj -c Release
dotnet test tests/Core/Tests.Core.csproj -c Release
```

On Linux, the adapter test passes generated output to the actual addon's `Ledger.New` loader (`Ledger.lua`) under Lua 5.1. Windows still runs the full .NET test suite; the Lua subprocess test is skipped there.
