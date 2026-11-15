# C12 investigation experience

## Product decisions

The primary workspace is **Activity**: a scoped view of completed attempts over
time, recipes contributing to them, actual production and gross reagent
commitment. Recipes and items open addressable investigations, not independent
administration dashboards. A recipe investigation contains its outcomes,
recorded configuration populations, comparison controls and contributing crafts.
An item investigation shows output, commitment and return roles independently.
Characters are filters and recipe comparison populations, not a leaderboard.

The shell owns a prominent context selector and context-wide recipe/item search.
**Library** contains pins, visibility preferences and saved investigations.
**Companion** is global management, with passive monitoring reassurance in the
shell. Management navigation retains the analytical destination.

Routes use backend-resolved aliases: `/:context/activity`,
`/:context/recipes/:id`, `/:context/items/:id`, `/:context/crafts`,
`/:context/crafts/:id`, and `/:context/library`. Global management is
`/companion`; saved definitions reopen through `/saved/:id`.
Entity IDs are opaque API identities. Query parameters carry each navigation
entry's period and compatible filters. Editing filters replaces that entry;
drill-down pushes a real link, preserving ordinary new-tab and back/forward
behavior. Search links intentionally start with independent defaults.

No tab state is synchronized through localStorage. Only the last canonical
context is remembered there as a best-effort startup convenience. Explicit URLs
always win. Context transitions unmount the old workspace before querying.

## Evidence and analytical boundary

C03 performs bounded, parameterized DuckDB aggregation against canonical crafts.
C11 exposes typed GraphQL results and preserves transport/security limits. C12
does not calculate rankings from downloaded observations. Quantity and count
results use exact decimal strings where JavaScript precision would be unsafe.

Completed attempts, actual output, gross allocations and returned materials
remain separate. Multicraft bonus is not added again to actual output. Proc rates
use observed denominators, not all attempts. Each measure exposes coverage;
incomplete collections remain visible as incomplete evidence. Forever input
quantities are labeled attributed schematic requirements, not measured usage.
Unsupported Retail measurements are omitted.

Comparisons use independently editable periods and recorded character,
configuration and input populations within the same recipe. Missing evidence is
not an absent buff, identical equipment or a no-resource configuration. Show
sample sizes, coverage, normalized outcomes and configuration differences.
Observational differences are not causal conclusions or predictions.
The comparison also matches character identities across both populations to
show their observed Ingenuity rates and percentage-point differences. Users can
choose confirmed resource absence in A and presence in B; unmatched or
unobserved populations remain insufficient evidence. It does not calculate
benefit per resource unit.

Configuration evidence is adapter-owned supplementary evidence, not a mutable
recipe catalog. Only explicitly supported, recorded fields may become analytical
facets; ambiguous variants remain unknown. No historical setup is invented.

Detailed results remain stable until explicit refresh. Polling a scope-specific
change signature can indicate relevant new or enriched evidence without
replacing displayed results. Summary refresh is automatic. Evidence drill-down
must disclose changed history instead of implying a durable snapshot.

## Durable organization

Pins and hidden entities use the existing context-qualified REST desired-state
mutations. Hiding only affects discovery/presentation, never analytical totals.
Failed preference loads are unavailable, not empty.

Saved definitions use an explicit versioned analytical document, without a
duplicated context field. The immutable REST envelope owns context and revision.
Definitions preserve relative or fixed periods, destination, filters and both
comparison populations. Validate before execution; unsupported definitions fail
explicitly. Changes are transient until explicitly saved; stale revisions
conflict and preserve unsaved work.

## Implementation and validation slices

1. Canonical aggregation, coverage, search and recorded population contracts;
   deterministic context/measurement tests.
2. Shell, URL scope, Activity, recipe and item investigations, comparisons and
   contributing craft inspection.
3. REST organization, executable saved definitions, global management and
   freshness/degraded states.
4. Integrated browser journeys, screenshots, responsive/accessibility review,
   generated contract checks and production route/publication regressions.

No new logical component, pricing integration, inventory model, persistence
snapshot system, chart framework or external runtime asset is introduced.
Validation results and remaining delivery work belong in the PR, not this
architecture document.
