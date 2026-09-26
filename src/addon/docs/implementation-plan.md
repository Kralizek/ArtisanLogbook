# Approved Implementation Plan

Scope: [issue #2](https://github.com/Kralizek/ArtisanLogbook/issues/2), with the
user's 2026-09-26 decisions below taking precedence over its suggestions.

## Execution and Gate

1. Build and test a small installable raw capture tracer.
2. Package it and install it in the actual live Retail/Midnight client.
3. Collect controlled basic, concentration, Ingenuity, Multicraft, and
   Resourcefulness traces. Include batch, duplicate/late callback, and
   cancellation/interruption observations. Orders may follow if inconvenient.
4. Document verified behavior, field availability, limitations, and proposed
   correlation rules against the actual client build.
5. Have the user and original agent review that contract.
6. Only after approval, implement the durable ledger against that evidence.
7. Continue through API/export, minimal UI, optional enrichment, and packaging.

Current boundary: tracer implementation only. Packaging and mocked tests are
not in-game installation, verification, or approval. Tests, packaging, and
product documentation live beneath `src/addon/`. See
[capture-tracer.md](capture-tracer.md) for installation and the evidence register.

## Reviewable Slices

1. **Tracer and capture contract:** raw event/call observations, bounded debug
   persistence, installable ZIP, synthetic harness, real traces, and review gate.
2. **Addon foundation:** evolve the tracer lifecycle into passive product
   capture. Preserve separate Core, Capture, Storage, Integrations, Flavors, and
   UI responsibilities without adding empty speculative modules.
3. **Durable storage:** evidence-backed craft/reagent schema, dimension registry,
   monotonic identities, independent versioning, migrations, and safe retention.
   Test migration failures and reload/prune behavior before depending on storage.
4. **Retail capture:** implement and replay-test the approved operation state
   machine, pre-craft facts, result merging, reagent attribution, procs, and
   order/recraft context. Never infer API-provided results from bag deltas.
5. **API and export:** bounded/filterable read access, isolated callback delivery,
   externally parseable versioned export, and golden round-trip fixtures.
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
- Persistence-schema, export-contract, and addon versions are independent.
  Monotonic craft IDs are never reused, including after prune/clear. Dimension
  IDs are also never recycled.
- Default detailed-ledger retention: `retentionDays = 180`, `maxCrafts = 50000`.
  Prune when either limit is exceeded; remove craft facts and their reagent
  facts together. Leave dimensions append-only. No dimension garbage collection
  or rollups in v1 unless later measurements justify a reviewed change. These
  defaults do not apply to the intentionally smaller temporary trace buffer.
- Store underlying facts, not derivable totals or proc flags: net concentration
  derives from spent/refund; Ingenuity from refund; Resourcefulness from returned
  quantities. Derivations must remain unknown when required inputs are unknown.
  The debug tracer deliberately retains raw API flags for contract inspection.
- Attach Resourcefulness returns to input reagent rows where attribution is
  unambiguous. A separate representation requires actual API evidence that
  reagent-level attribution is impossible. Never invent commodity provenance
  after stacks merge.

## API Direction

The initial public surface is expected to include:

```text
ArtisanLogbookAPI.GetCrafts(filter)
ArtisanLogbookAPI.GetCraft(id)
ArtisanLogbookAPI.GetRecipeStats(recipeID)
ArtisanLogbookAPI.RegisterCallback(event, callback)
ArtisanLogbookAPI.GetCapabilities()
```

Signatures may be refined with a documented reason. Consumers must not access
or mutate SavedVariables/internal tables, and integrations must not depend on
UI code. Do not implement `GetObservedCost`; valuation, material provenance,
intermediate crafts, and inventory accounting are deliberately unresolved.

## UI and Integrations

Recent is primarily a craft-verification surface. Stats derives values from
persisted facts rather than persisting aggregates. Data contains retention,
export, integration status, diagnostics, prune, and clear. Large histories must
not trigger unbounded rendering. The first-slice debug window is not a premature
implementation of these ledger views.

CraftSim and TSM are optional. Absent, incompatible, throwing, or incomplete
providers must not affect base logging. Use supported/stable APIs only and store
small point-in-time snapshots with provider/version context. Do not duplicate
their databases, accounting, inventories, optimizers, or other responsibilities.

## Validation and Documentation

Use Lua 5.1-compatible tests with mocked WoW boundaries; turn reviewed live
traces into clearly attributed fixtures. Verify reloads, migrations, both
retention limits, dimension integrity, unknowns, callback correlation, export
round-trips, and provider failure modes as the relevant slices are introduced.
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
