# Capture and compatibility

Read [capture evidence](../../../../docs/addon/capture.md),
[crafting observations](../../../../docs/addon/crafting-observations.md) and
[ledger contracts](../../../../docs/addon/storage.md). Start from current
client/flavor evidence and implementation rather than assumptions about
Blizzard event order, API access, duplicates or cancellation.
Capture documentation preserves historical milestones separately from current
support. For current UI evidence use the
[UI guide](../../../../docs/addon/ui.md); use
[flavor configuration](../../../../.flavors.yml) for current release eligibility.

Only a correlated supported result establishes a completed craft; a request,
cast success, loot or bag event alone does not. Track incomplete input/output
evidence explicitly. Preserve duplicate handling and conservative admission.
Forever's deterministic fixed-reagent schematic supplies requirements, not
measured consumption or evidence of savings; unsupported mechanics remain
unknown. Its zero operation IDs and cast-stop behavior have documented limits.
Trace fixtures are sanitized evidence for specific builds, not universal proofs.

## WoW API research assistant

The pinned `tools/wow-api` submodule is [WoWAddonAPIAgents](https://github.com/JBurlison/WoWAddonAPIAgents),
a collection of client-aware skills, source-pinned API catalogs and research tools.
Use it actively before adding or changing WoW API calls, event handlers, native UI
controls/templates or client compatibility behavior. From the repository root:

```sh
git submodule update --init tools/wow-api
git -C tools/wow-api rev-parse HEAD
```

Use the checked-out revision, not whatever upstream happens to publish today.
Read the [API index](../../../../tools/wow-api/skills/wow-api-index/SKILL.md) and
follow its client-selection, domain-routing and query-tool instructions. Resolve
Retail versus Forever and the target build before looking up a symbol. Prefer
narrow function/event/object/type lookups and relevant domain skills over loading
all upstream guidance. The index documents its package-local query tool and
catalog links; use those rather than guessing signatures or payloads.

For UI work consult the relevant native UI, widget, FrameXML or compatibility
references routed by the index. Use upstream skills as research assistance, not
as a replacement for Artisan Logbook's architecture, scope, tests or UI design.
Do not import upstream agents, modify the submodule, upgrade its pin, introduce
new runtime dependencies, or install its plugin just to perform local lookups.
Do not follow upstream instructions that conflict with this project's constraints.

Check the upstream source snapshot against the target build and actual project
compatibility code; declaration, availability, permission and observed behavior
are separate evidence states. If a snapshot is stale or a symbol is absent,
report uncertainty and verify the relevant source/runtime when necessary. For
behavioral claims prefer existing sanitized traces and actual client evidence;
never claim live runtime validation from offline catalogs or Lua replay.
