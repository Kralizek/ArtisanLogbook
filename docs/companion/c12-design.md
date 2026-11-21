# C12 investigation experience

## Journal refinement (November 2026)

The addon is the everyday mental model, with the analytical workbench one
deliberate step deeper. Existing context-qualified routes and saved definitions
remain valid. No external artwork or fonts are fetched.

| Destination | Main question / initially visible | Default controls | Secondary content and drill-down |
| --- | --- | --- | --- |
| Overview | What have I crafted? Compact totals, elapsed-time activity, bounded recipe and material previews | Period; meaningful character/profession choices | Full catalogues; recipe, item and Logbook links; optional detailed reports |
| Logbook | What happened in each attempt? Paged observations | Period, character, profession | Craft Result / Ingredients / Configuration |
| Recipes | Which recorded recipe should I inspect? Searchable all-history catalogue | Name / ID search; inherited scope is retained for detail links | Recipe Overview / Statistics / Craft History / Reagents |
| Reagents & items | Which materials are involved? Item catalogue, including outputs and returns | Name / ID search | Separate production, gross commitment and return relationships; inherited recipe chip |
| Characters / Professions | Whose activity am I exploring? Recorded identity shortcuts | Name search | Scoped Overview and Logbook, not leaderboards |
| Library | What did I organize? Pins, hidden entities, saved investigations | Collection controls | Explicit updates, restoration, forks and revision conflicts |
| Settings | Is collection working? Installations, effective monitoring, manual imports | Browser-led discovered installation choice | Import receipts/warnings and diagnostics; explicit restart boundaries |

Pinned recipes live in an independently scrolling sidebar section. Settings
remains anchored outside it. The shell uses warm charcoal framing, parchment
content, antique gold selection and muted green activity. Major headings use a
local serif fallback; dense content retains the readable system sans-serif.
No copyrighted game artwork is redistributed or inferred from absent metadata.

Recipe comparison starts from a question: characters, finishing reagent,
recorded buff, before/after, or custom. Guided choices write the same independent
population filters as the custom workbench; they never reinterpret unknown
evidence as absence. Full filters and configuration variants remain accessible,
but do not dominate ordinary exploration. Saves are explicit, progressively
disclosed actions. Changing a relative period removes inactive fixed bounds.

Review F01–F17 is tracked in the PR with measured validation, not implied by
moving components. Canonical expansion grouping and applied-refund semantics
are corrected at the backend boundary; visual simplification does not change
analytical populations.

### Representative surfaces

Synthetic recorded observations illustrate the [light Overview](images/web-overview.png),
[warm dark theme](images/web-overview-dark.png), [narrow layout](images/web-overview-narrow.png),
[recipe investigation](images/web-recipe.png) and [Logbook](images/web-history.png).
Setup display codes remain stable across filtered populations and craft details;
they are presentation labels, not invented equipment names or analytical identities.

## Product decisions

The primary workspace is **Overview** (the compatible `activity` route): a scoped view of completed attempts over
time, recipes contributing to them, actual production and gross reagent
commitment. Recipes and items open addressable investigations, not independent
administration dashboards. A recipe investigation contains its outcomes,
recorded configuration populations, comparison controls and contributing crafts.
An item investigation shows output, commitment and return roles independently.
Characters are filters and recipe comparison populations, not a leaderboard.

The shell owns a prominent context selector and context-wide recipe/item search.
**Library** contains pins, visibility preferences and saved investigations.
**Settings** is global Companion management, with passive monitoring reassurance in the
shell. Management navigation retains the analytical destination.

Routes use backend-resolved aliases: `/:context/activity`,
`/:context/recipes/:id`, `/:context/items/:id`, `/:context/crafts`,
`/:context/crafts/:id`, and `/:context/library`. Bounded catalogues use
`/:context/recipes`, `/:context/items`, `/:context/characters`, and
`/:context/professions`. Global management is
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
The comparison matches character identities across both populations and lets
players select observed proc/occurrence rates or actual output per measured
craft. Retail comparisons can also select a particular returned material and
compare its quantity per craft without filtering either population to crafts
that returned it. The chosen outcome and material are part of the address and
saved definition. Returned-item averages require complete return evidence and
known item quantities; an explicitly complete return set with no item row
records absence, while a row with an unknown quantity remains unknown.
Separate returned-item queries are displayed only when their evidence signatures
match the retained populations. Output
counts units across recorded items; item investigations provide the individual
material context. Users can choose confirmed resource absence in A and presence
in B; unmatched or unobserved populations remain insufficient evidence. When
those filters refer to the same finishing reagent, or to the confirmed absence
and presence of the same input item, complete recorded allocations and complete
outcome observations permit the observed difference to be normalized by the
average allocated units per B craft, provided A has no allocation of that item
and B's allocation is positive. Input absence requires complete input evidence
and either a known zero or no row for that item. Absence as a finishing reagent
alone does not establish that the item was not allocated in another role. This
is not measured consumption or a causal effect; allocations can originate from
a multi-craft request and be repeated across crafts. In Forever, the same
normalization is labeled as attributed schematic requirements, not allocation
or measured consumption.

Configuration evidence is adapter-owned supplementary evidence, not a mutable
recipe catalog. Only explicitly supported, recorded fields may become analytical
facets; ambiguous variants remain unknown. No historical setup is invented.

Detailed results remain stable until explicit refresh. Polling a scope-specific
change signature can indicate relevant new or enriched evidence without
replacing displayed results. Summary refresh is automatic, including advancing
the bounds of rolling periods. Evidence drill-down must disclose changed history
instead of implying a durable snapshot.

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
