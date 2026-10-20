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
| session version/build/capabilities, `configurations` | Operational metadata | Not canonical craft facts; explicit regeneration emits existing configuration rows but does not invent historical session metadata |

The recorder's `outcomeSource`, `hasResourcefulnessProc`, and `resourcefulnessComplete` are separate evidence. Missing `returnedQuantity` remains unknown, while an explicit zero remains zero. Allocation slots and independent item-level return rows are summed separately: a return-only row does not erase known allocations, and an allocation-only row does not erase a known return. Pre-`outcomeVersion = 2` schema-1 observations follow the addon's documented correction: unproven false/set-completeness claims become unknown; retained positive evidence survives. No aggregate quantity is allocated back to a craft. Core dimensions are scoped by game context, including repeated item, recipe, and profession IDs.

## Lua subset and API

`LuaDataParser` accepts only:

- top-level `ArtisanLogbookDB = { ... }`/other global assignments or one `return { ... }`;
- nested table constructors, implicit sequence entries, non-keyword identifier fields, numeric/string/boolean keys, finite numbers, booleans, `nil`, UTF-8 quoted strings and Lua 5.1 short-string escapes;
- line comments and `--[[...]]` comments.

It never evaluates Lua. Calls, functions, operators, metatables, long strings, and arbitrary expressions are rejected with source line/column diagnostics. Input size, nesting, and table-entry limits are bounded. Assigning `nil` removes a table field, as in Lua; escaped physical newlines remain newlines. Decimal byte escapes are decoded as UTF-8; non-UTF-8 binary strings and newer-Lua escapes such as `\z` are explicitly unsupported, not silently converted. Truncated tokens/comments and numeric overflow produce diagnostics rather than escaping as indexing/arithmetic exceptions.

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
        SourceCoverage: parsed.Coverage,
        ExistingTargetPolicy: SavedVariablesTargetPolicy.Regenerate));
if (!exported.IsSuccessful)
    throw new InvalidDataException(string.Join(Environment.NewLine, exported.Diagnostics));

string convertedText = exported.Content!;
```

`SavedVariablesReader.Parse` supports ledger schema versions 1–4. It interprets their persisted craft facts directly; it does not run the addon's Lua migrations or apply retention pruning. Malformed schema/layout, unknown project, conflicting project references, unstable character identity, and unsupported schema versions are reported explicitly. Individual crafts with unestablished required identity/context are not promoted.

Craft/request links must agree on session and recipe before request-only input fallback is permitted; orphan reagent references and malformed collection members fail explicitly. That fallback includes both allocation slots and fixed reagents without inventing returns. Recipe dimension enrichment remains independent of per-craft classification, and profession parents use `companionParent` because the actual loader rejects native `parentId`/`professionId` fields on profession rows.

The current source supplies `projectId` on each session, but has no trusted progression-track field. The adapter reads a `companionProgressionTrack` session extension only when it was explicitly serialized by this adapter; it never infers a track from the build, version, date, or profession expansion. Existing ledgers without `projectId` cannot be safely classified.

## Identity and reconciliation

For legacy input, the deterministic Core origin uses the project, stable character key, and persisted session key; the observation uses the ledger-local craft ID. This is replay-stable for the same ledger snapshot, and the original operation/request/session values remain in `CraftProvenance`. The adapter emits a `legacy-identity-lineage` warning because the addon's current format has no durable source-ledger lineage. Copies that diverged while reusing a session/local craft ID can be indistinguishable from one craft with conflicting facts—or from distinct crafts with identical facts. The adapter does not guess; use [`CraftHistoryReconciler`](../Core/History/CraftHistoryReconciler.cs) to surface known collisions.

Minimal addon follow-up: persist a durable ledger lineage ID and a source-assigned craft observation ID that survives file copies, and define how a copied ledger changes lineage when independent recording begins. Add a first-class progression-track value only where the game supplies trustworthy project/track evidence. Until then, legacy ambiguity remains a documented limitation; see [#51](https://github.com/Kralizek/ArtisanLogbook/issues/51) for the focused recorder-lineage follow-up.

Recipe/item IDs remain Blizzard numeric IDs scoped by `GameContext`. Recovered recipe IDs are accepted only when the source has recorded them (or when rows were deliberately grouped by this adapter's companion metadata). No recipe fingerprints, content-era namespaces, catalog integration, GUID identities, or cross-game equivalence are introduced.

## Serialization, rollups, and limitations

The writer emits a complete schema-4 `ArtisanLogbookDB` assignment with collision-free local craft, session, character, and expansion IDs and consistent references. A single output row per item/quality is emitted for multi-output observations; companion grouping metadata lets the reader restore one canonical observation. Coverage diagnostics count those logical observations, not physical output rows, and sum operational rollup grains before subtracting detail. Conflicting shared facts in a group are rejected, not resolved by choosing its first row. Adapter-only metadata is namespaced `companion*`; tests verify it survives the actual loader.

Before returning content, the writer reparses it and checks exact semantic equality of all retained canonical craft observations. Unsafe integer quantities/rollup sums and unrepresentable fractional precision fail explicitly rather than returning subtly changed observations. Subsecond timestamps, independent per-craft profession/expansion classification, absent versus empty collections, and original operation/request/session provenance use companion metadata where native fields cannot represent them.

Detailed craft/reagent rows are limited to `RetentionDays` (default 60); `craftSeries`, `reagentSeries`, and `resourcefulnessSets` are regenerated from every craft observation supplied, including older observations. If the source contained rollup-only/pruned periods, the reader reports them and the writer carries that coverage warning forward when `SourceCoverage` is supplied. It does not fabricate crafts.

### Existing-target regeneration contract

`existingTargetState` is **not a lossless merge/backup API**. With an existing `ArtisanLogbookDB`, the default `SavedVariablesTargetPolicy.Reject` returns `target-regeneration-policy-required`. Explicit `Regenerate` consent enables the following guarded operation:

1. Parse the existing target and reject unsupported/invalid history or mismatched/unknown session game contexts.
2. Use Core's `CraftHistoryReconciler` to verify that **every target craft and its known evidence are already included in the supplied history**. Missing crafts, conflicts and missing enrichment return `target-history-not-reconciled`; the writer never silently ingests them on the caller's behalf.
3. Emit a `target-operational-state-regenerated` warning describing replaced/discarded row counts. Automatically diagnose aggregate-only target coverage even if the caller omitted `SourceCoverage`.
4. Preserve unrelated global assignments, ungenerated ledger settings, matching character descriptive metadata and existing configuration rows/counter allocation. Rebuild dimensions, synthetic sessions, recent craft/reagent rows, recipe-output relationships and supported rollups from canonical observations. Remove obsolete schema-1 `outcomeVersion`/`returnedReagents` fields.
5. Explicitly discard native requests, first-craft rewards, requirement rollups, original session metadata, and craft-linked configuration/requirement/request evidence. Do not blindly merge old aggregates or invent submission facts.

Configuration rows survive the **emitted file**, not a promise of permanent addon retention: `Ledger:Prune` removes configuration rows no longer referenced by facts. Restored facts do not regain their historical configuration links. Unreferenced dimensions/recipe-output knowledge are regenerated rather than preserved.

C09 must preview these diagnostics, ingest/reconcile the latest target, obtain explicit restoration consent, retain a verified backup, check that WoW is not running, and perform validated filesystem replacement/recovery. None of those orchestration or filesystem actions belongs to this library. A returned-table fixture is valid reader input; existing target state must use SavedVariables global assignments.

The following limits are intentional:

- A SavedVariables ledger represents one selected `GameContext`; exporting several contexts requires one conversion per context. The writer rejects implicit multi-context selection.
- The Core model does not contain historical recipe input requirements, first-craft reward observations, quote/configuration snapshots, or every request's operational intent. Those are not recreated as craft facts. First-craft reward rollups are cleared; `reagentRequirementSeries` is empty because no canonical per-craft requirement fact exists.
- Detailed `InputsComplete` and Resourcefulness completeness/source evidence use companion metadata if the old addon's native field requires request state absent from the canonical craft model. The addon's native `requests` array is not reconstructed with guessed `useConcentration` or requested counts.
- The addon rejects an explicit zero `allocatedQuantity` (its `isInteger` requires a positive integer). Canonical zero is therefore stored as `companionAllocatedQuantity = 0`, with the native field absent. Unknown remains absent, and positive allocations use the native field. Zero allocations do not create positive addon allocation coverage; the reader restores zero exactly.
- Complete Resourcefulness **does not imply native authority**: only original `ResourcefulnessEvidence = "native"` produces native/authoritative counts. Legacy complete sets stay non-authoritative. Complete false/no-proc observations are supported. Restored native facts set `materialsSavingsEligible = false`; missing historical submission/requirement eligibility cannot justify matched material-savings populations.
- The addon's schema has one primary output per persisted craft row. The writer uses several compatible rows for a known-recipe canonical multi-output craft and emits grouping metadata; imported rows without this metadata remain separate source craft records. Native detail views still show physical rows, not a new addon logical-craft subsystem.
- **Unknown-recipe restoration is rejected for multi-output observations or complete companion-only inputs** (`unsupported-unknown-recipe-restoration`). Actual `Ledger:RepairUnknownRecipes` tests exposed invalid physical-row contribution moves and loss of companion-only coverage. Import/canonical retention are supported, but verified recipe enrichment through C02 is required before exporting these cases until focused addon follow-up [#53](https://github.com/Kralizek/ArtisanLogbook/issues/53) is addressed. Basic single-output unknown-recipe repair, including native returns, is tested end to end.
- Sessions are explicitly `companionSynthetic = true`, start at export time, and contain no copied historical build, addon version, locale or capabilities. Craft-level source IDs, original session/request/operation IDs and Resourcefulness provenance survive independently, even for crafts originally from different sessions. Core does not model historical session builds/timestamps/capabilities; preserving those would require a separate source-metadata contract, not falsely attributing one target session's metadata to all history. No session-history subsystem is introduced.
- Fractional legacy returned-material measurements are preserved as `decimal` in Core; Lua's numeric runtime remains IEEE-754. Values that cannot round-trip through that representation without changing the canonical observation are rejected.
- The repository has sanitized historical and synthetic cases, not a live installation export. A sanitized current schema-4 capture should be added once the project can provide one without exposing personal character data.
- The raw schema-3 fixture has deliberately unresolved project/character metadata and is rejected, not assumed Retail. A clearly synthetic context-enriched variant exercises schema-3 conversion/loader compatibility. Schema-2 conversion is likewise exercised with a generated supported-layout case, not misrepresented as a live snapshot.
- No emergency capture stream is inferred from diagnostic traces. A future fallback recorder must supply authoritative game/character context and distinct durable observation lineage before C04/C02 can import/reconcile it safely; #51 tracks that recorder contract, not an in-adapter identity guess.

No output is written to the filesystem. Callers remain responsible for choosing where returned text goes; this library never replaces a live SavedVariables file.

## Tests

From `src/companion`:

```sh
dotnet test tests/SavedVariables/Tests.SavedVariables.csproj -c Release
dotnet test tests/Core/Tests.Core.csproj -c Release
```

On Linux, tests require `lua5.1`, pass generated output to the actual addon's `Ledger.New` loader (`Ledger.lua`), serialize its resulting database and reimport it to verify craft semantics after loading. Cases cover zero allocations, sessions, native/non-native outcomes, schema 1-4 conversions, actual supported recipe repair and 100 seeded randomized round trips. Every truncated prefix of a Lua sample is also checked for exception safety. Windows runs all .NET assertions but does not execute the Lua subprocess portions.
