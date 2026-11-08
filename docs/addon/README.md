# In-game addon documentation

The [Artisan Logbook addon](../../README.md) records crafting activity in World of Warcraft. Core captures and stores observations; UI provides the in-game browser; Tracer is optional and intended for diagnostics.

## Getting started

- [Deployment and supported clients](deployment.md) — installation, local builds, Retail and Forever, release procedures.
- [In-game interface](ui.md) — views, navigation, interaction and visual acceptance.

## Technical reference

- [Craft capture and Tracer](capture.md) — event recording, diagnostic traces and evidence boundaries.
- [Crafting observations](crafting-observations.md) — operation correlation and provenance.
- [Ledger and retention](storage.md) — SavedVariables schema, durable facts and aggregates.
- [Resourcefulness measurements](resourcefulness.md) — coverage, normalization and statistical integrity.
- [Public Lua API](lua-api.md) — projections and callbacks.
- [Diagnostics inspector](diagnostics.md) — `/al_debug` and troubleshooting.

For build and test commands, see [CONTRIBUTING](../../CONTRIBUTING.md).
