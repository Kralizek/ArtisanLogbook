# Approved Implementation Plan

Scope: [issue #2](https://github.com/Kralizek/ArtisanLogbook/issues/2), with the
user's 2026-09-26 decisions below taking precedence over its suggestions.

## Execution and Gate

1. Build and test a small installable raw capture tracer.
2. Package it and install it in the actual live Retail/Midnight client.
3. Collect controlled basic, concentration, Ingenuity, Multicraft, and
  Resourcefulness traces. The supplied Retail build-69933 evidence now covers
  basic results, concentration without Ingenuity, Multicraft, Resourcefulness,
  and a two-operation batch. The newly verified Ogrim export establishes successful
  Ingenuity (`hasIngenuityProc=true`, spend 323, refund 162).
  Cancellation/interruption remains outstanding. Include duplicate/late callback observations. Orders
  and actual recrafts remain follow-up evidence.
4. Document verified behavior, field availability, limitations, and proposed
   correlation rules against the actual client build.
5. Have the user and original agent review that contract.
6. Implement the durable ledger against the reviewed evidence (completed in
  issue #4).
7. Continue through the stable Lua API, minimal UI, optional enrichment, and packaging. Portable export remains a separate later concern.

Completed slices: installable tracer/evidence review and durable versioned
storage. Packaging and mocked tests are not in-game installation or verification.
Addon implementation/tests live beneath `src/addon/`; shared product documentation
lives under the repository-level `docs/` directory so addon, exporter, and web
documentation can coexist. See
[capture-tracer.md](capture-tracer.md) for the PR #3 evidence register and
[storage-ledger.md](storage-ledger.md) for the issue #4/#12 storage contract and
[lua-api.md](lua-api.md) for the issue #5 public consumer contract.

## Reviewable Slices

1. **Tracer and capture contract:** raw event/call observations, bounded debug
  persistence, installable ZIP, synthetic and sanitized real-trace replay,
  verified capture findings, and review gate.
2. **Addon foundation:** evolve the tracer lifecycle into passive product
   capture. Preserve separate Core, Capture, Storage, Integrations, Flavors, and
   UI responsibilities without adding empty speculative modules.
3. **Durable storage (issue #4):** evidence-backed craft/reagent schema,
   dimension registry, monotonic identities, independent versioning, migrations,
   and safe retention. Implemented; see [storage-ledger.md](storage-ledger.md).
4. **Additional Retail capture:** implement pre-craft facts, verified reagent
  allocation, and order/recraft context as evidence becomes available. Successful
  Ingenuity proc/refund behavior is now verified from the Ogrim export and is used
  by the daily-series contract. Issue #4 ingests result callbacks only; never infer
  API-provided results from bag deltas.
5. **Stable Lua API (issue #5):** denormalized read projections, shared
   dimension filters, bounded cursor paging, strict/self-excluding facets,
   durable daily craft series, runtime capabilities, and isolated callback delivery. Portable export is a
   separate later concern.
6. **Minimal UI:** Recent, Stats, Data; bounded rendering and explicit destructive
   action confirmation. Validate live captured results against the game UI.
7. **Enrichment and distribution:** supported CraftSim/TSM snapshots with fault
   isolation, final package validation, and documented limitations. Forever is
   separate follow-up work after its exact client/API is verified.

Tests and documentation accompany each slice rather than being deferred.

## Fixed Decisions

- Live Retail/Midnight is authoritative for v1. A shared flavor registry and
   capability boundary dispatch by client project ID; Retail is currently the
   only implemented adapter. Other flavors remain loadable with explicit empty
   capabilities. Forever does not block v1 and its API-specific adapter remains
   deferred until the exact client/API is verified.
- Unknown/unavailable measurements remain absent/nil, never fabricated zeroes.
  Capability availability alone does not prove a measurement's semantics.
- Use account-wide SavedVariables. Character identity belongs in dimensions,
  not separate per-character databases. Raw debug metadata is not the final
  dimension or craft schema.
- Persistence schema, public Lua API, portable export contract, and addon
  version are separate boundaries. Monotonic craft IDs are never reused,
  including after prune/clear. Dimension IDs are also never recycled.
- Updated by the issue #5 runtime indexing/retention decision: default
  `retentionDays = 60`, with no `maxCrafts` threshold. Maintain durable daily
  craft-count/output/Multicraft/concentration and verified Ingenuity proc/applied-refund
  series with metric coverage.
  Prune detailed facts at startup before
  building runtime indexes, not on submissions/results; remove craft facts and their reagent
  facts together. Leave dimensions append-only. No dimension garbage collection
  or reagent-level rollups in v1; durable daily craft series are approved in issue #5. These
  defaults do not apply to the intentionally smaller temporary trace buffer.
- Store source measurements and flags needed for derivation; do not persist
  duplicated derived totals. Apply `ingenuityRefund` only when
  `hasIngenuityProc` is explicitly true; an explicit false means applied refund
  zero, while an absent/unknown flag leaves applied refund unknown. Derive net
  concentration as spent minus applied refund only when both inputs are known.
  A positive refund field alone is not evidence of an Ingenuity proc. Derive
  Resourcefulness from returned reagent quantities. The debug tracer retains
  raw API values and flags for contract inspection.
- Live build-69933 traces make `operationID` the leading candidate for
  per-actual-operation identity: one count-2 request produced two result
  callbacks with distinct non-zero IDs. This is current-trace evidence, not a
  universal guarantee. A craft fact represents an actual operation/result
  rather than a request; spellcast events remain supporting evidence, and
  `itemGUID` is not craft identity. The issue #4 store follows these findings
  without treating `operationID` as a universal uniqueness guarantee.
- Attach Resourcefulness returns to input reagent rows where attribution is
  unambiguous. A separate representation requires actual API evidence that
  reagent-level attribution is impossible. Never invent commodity provenance
  after stacks merge.

## Dimension Model

The durable storage slice implements this model in
[storage-ledger.md](storage-ledger.md). Keep expansion/era classification on
dimensions rather than duplicating it across craft or reagent facts:

- Add an append-only `ExpansionDimension` (or equivalent era dimension) with
  an ID, stable key/slug, display name, and chronological order value. Keep
  stable identity separate from display naming; do not recycle dimension IDs.
- `ItemDimension` may reference its own expansion through a nullable
  `introducedInExpansionId` (or equivalent ownership/introduction metadata).
  This describes the item itself, not the expansion of any craft that uses it.
- `RecipeDimension` may reference its expansion through a nullable
  `expansionId`. A craft's expansion is normally derived by joining its recipe
  dimension, not by storing a second expansion value on each craft fact.
- Profession/skill-line dimensions may have a nullable expansion reference
  where the WoW API models that profession or skill line as expansion-specific.
- Reagent facts normally obtain expansion context through their item dimension.
  Generic, vendor, and reused materials can be used by recipes from multiple
  expansions; never assign an item's expansion from a consuming craft.
- Leave unavailable or unknown dimension references absent. Do not infer them
  from recipe use, current client expansion, labels, or other indirect context.
- Dimension identities and IDs are append-only, not all metadata. Nil-to-known
  enrichment is allowed atomically; conflicting known metadata is rejected.

The storage contract defines current keys and validates references. The actual
era/expansion catalog and runtime enrichment sources still need verified game
data. No guessed mapping is populated by the storage slice.

## API Direction

The stable public surface from issue #5 is:

```text
ArtisanLogbookAPI.GetCraft(id)
ArtisanLogbookAPI.GetCrafts(filter, options)
ArtisanLogbookAPI.GetCraftSeries(filter, options)
ArtisanLogbookAPI.GetFacets(filter, options)
ArtisanLogbookAPI.GetCapabilities()
ArtisanLogbookAPI.RegisterCallback(event, callback)
```

Consumers receive denormalized domain projections and must not access or mutate
SavedVariables/internal dimension rows. The initial shared filter covers absolute
time, character, realm, expansion, profession, and recipe. Craft context and
flavor-/result-specific properties such as concentration remain deliberately
deferred. Paging/sorting belongs to `GetCrafts`; facet computation supports
self-excluding and strict modes through `GetFacets`.

Do not add `GetRecipeStats` or `GetObservedCost` to the first stable contract.
Derived analytics, valuation, material provenance, intermediate crafts, and
inventory accounting remain deliberately unresolved.

See [lua-api.md](lua-api.md) for the exact v1 contract.

## UI and Integrations

Recent is primarily a craft-verification surface. Stats should consume the
appropriate persisted source for its question: detailed retained craft facts for
drill-down and the durable daily craft series for long-range trends. Do not create
additional ad-hoc aggregate stores without a reviewed contract. Data contains retention,
export, integration status, diagnostics, prune, and clear. Large histories must
not trigger unbounded rendering. The first-slice debug window is not a premature
implementation of these ledger views.

CraftSim and TSM are optional. Absent, incompatible, throwing, or incomplete
providers must not affect base logging. Use supported/stable APIs only and store
small point-in-time snapshots with provider/version context. Do not duplicate
their databases, accounting, inventories, optimizers, or other responsibilities.

## Validation and Documentation

Use Lua 5.1-compatible tests with mocked WoW boundaries; turn reviewed live
traces into clearly attributed fixtures. Verify reloads, migrations, time-based
retention, dimension integrity, unknowns, callback correlation, API
filtering/paging/facets, and provider failure modes as the relevant slices are introduced.
Portable-export round trips belong to the later export-format work.
In-game traces remain the authority, not mocks or source declarations.

Document the verified event contract, supported-field/capability matrix, API
limitations, chosen architecture, storage schema, migration behavior, and
in-game checklist near the addon or under `docs/`. Keep the root README minimal.
Each implementation PR should explain its completed slice, evidence, tests,
limitations, divergences from the issue, and what remains behind the gate.

No web app, .NET exporter, pricing/profit strategy, inventory costing, sales
reconciliation, or release publishing is part of this initial addon work. The
packaged artifact should be self-contained and reusable by future release
automation; do not introduce unnecessary vendored libraries or Ace dependencies.
