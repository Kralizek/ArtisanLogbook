# Artisan Logbook

**Artisan Logbook** is a World of Warcraft addon for keeping a record of your crafting activity. Browse past crafts, explore recipes and reagents, and review the crafting outcomes the addon was able to observe.

## What you can do

- **Browse crafting history** by character, profession, recipe, and time period.
- **Explore recipes and reagents** to see recorded outputs, inputs, and returned materials.
- **Review crafting statistics**, including supported profession outcomes such as Resourcefulness, Multicraft, and Ingenuity when the game provides sufficient evidence.
- **Organize the view** with recipe pinning/hiding and reagent preferences.

Recorded observations are not the same as guaranteed measurements. Older or unsupported crafting operations may have incomplete input or outcome data; the addon should not present missing measurements as zero.

## Install and open

For a normal Retail installation, install the **combined Artisan Logbook bundle**. It includes:

| Addon | Purpose |
| --- | --- |
| `ArtisanLogbook_Core` | Captures crafting events and stores history |
| `ArtisanLogbook` | In-game browser and statistics UI; requires Core |
| `ArtisanLogbook_Tracer` | Optional diagnostic recorder; disabled by default |

Open the in-game browser with `/al` or `/artisanlogbook`.

If installing separately, enable **Core and UI**. Tracer is not needed for normal gameplay. See [installation and supported game clients](docs/addon/deployment.md) for manual, local, and flavor-specific installation details.

## Other tools

The optional [Companion CLI](src/companion/README.md) imports SavedVariables snapshots into a separate local DuckDB history database. It does not replace the in-game browser.

Core also exposes a developer-only read-only inspector with `/al_debug`. See [diagnostics](docs/addon/diagnostics.md) if you are troubleshooting capture.

## Documentation

- [Documentation index](docs/README.md)
- [In-game interface and features](docs/addon/ui.md)
- [Installation and release information](docs/addon/deployment.md)
- [Companion CLI](src/companion/README.md)
- [Troubleshooting and diagnostic recording](docs/addon/capture.md)
- [Contributing and local development](CONTRIBUTING.md)

Artisan Logbook is an independent community project for World of Warcraft.
