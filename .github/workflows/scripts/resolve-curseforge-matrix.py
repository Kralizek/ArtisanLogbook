#!/usr/bin/env python3
"""Resolve configured CurseForge game versions into a GitHub Actions matrix."""

import json
import os
import re
from pathlib import Path

import yaml


def resolve_matrix(config: dict, addon_version: str) -> dict:
    rows = config.get("gameVersions")
    if not isinstance(rows, list) or not rows:
        raise ValueError("gameVersions must be a nonempty array")

    names: set[str] = set()
    matrix: list[dict] = []
    for entry in rows:
        if not isinstance(entry, dict):
            raise ValueError("Each game version must be an object")
        name, version, game_id = entry.get("name"), entry.get("version"), entry.get("id")
        if not isinstance(name, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", name) or name in names:
            raise ValueError(f"Invalid or duplicate flavor: {name!r}")
        names.add(name)
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError(f"Invalid game version for {name}: {version!r}")
        if type(game_id) is not int or game_id <= 0:
            raise ValueError(f"Game version ID for {name} must be a positive integer")
        major, minor, patch = map(int, version.split("."))
        # The current unqualified bundle is Retail-specific. Other flavors
        # require their own explicitly named release asset.
        suffix = "" if name == "retail" else f"-{name}"
        matrix.append({
            "name": name,
            "version": version,
            "id": game_id,
            "interface": major * 10000 + minor * 100 + patch,
            "asset": f"ArtisanLogbook-Bundle{suffix}-{addon_version}.zip",
        })

    return {"include": matrix}


def main() -> None:
    addon_version = os.environ["VERSION"]
    config = yaml.safe_load(Path(".curseforge.yml").read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError(".curseforge.yml must contain a mapping")
    matrix = resolve_matrix(config, addon_version)
    rendered = json.dumps(matrix, separators=(",", ":"))
    print(rendered)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={rendered}\n")


if __name__ == "__main__":
    main()
