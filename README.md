# Artisan Logbook

The native in-game browser opens with `/al` or `/artisanlogbook`. See
[production UI](docs/production-ui.md) for the views, data controls and in-game
validation checklist. Install the bundle, or install both `ArtisanLogbook` (UI)
and its required `ArtisanLogbook_Core` (capture and durable facts). The UI reads
Core via `ArtisanLogbookAPI`; engineering tracing is available through `/altrace`.
