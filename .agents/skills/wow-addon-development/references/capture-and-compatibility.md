# Capture and compatibility

Read [capture evidence](../../../../docs/addon/capture.md),
[crafting observations](../../../../docs/addon/crafting-observations.md) and
[ledger contracts](../../../../docs/addon/storage.md). Start from current
client/flavor evidence and implementation rather than assumptions about
Blizzard event order, API access, duplicates or cancellation.
Capture documentation retains older milestone statements about Forever UI and
release eligibility. For current UI evidence use the
[UI guide](../../../../docs/addon/ui.md); use
[flavor configuration](../../../../.flavors.yml) for current release eligibility.

Only a correlated supported result establishes a completed craft; a request,
cast success, loot or bag event alone does not. Track incomplete input/output
evidence explicitly. Preserve duplicate handling and conservative admission.
Forever's deterministic fixed-reagent schematic supplies requirements, not
measured consumption or evidence of savings; unsupported mechanics remain
unknown. Its zero operation IDs and cast-stop behavior have documented limits.
Trace fixtures are sanitized evidence for specific builds, not universal proofs.

Use the [vendored API index](../../../../tools/wow-api/skills/wow-api-index/SKILL.md)
and its source-pinned client declarations alongside repository compatibility
modules for the selected flavor. Initialize the submodule if it is absent.
Verify availability and behavior in that actual client where necessary; do not
claim live runtime validation from Lua replay.
