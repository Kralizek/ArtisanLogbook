#!/usr/bin/env python3
"""Resolve provider-neutral flavor configuration to an addon release matrix."""

import json
import os
import re
from pathlib import Path

import yaml


def resolve_matrix(config: dict, addon_version: str) -> dict:
    rows = config.get("flavors")
    if not isinstance(rows, list) or not rows:
        raise ValueError("flavors must be a nonempty array")

    seen = set()
    matrix = []
    for entry in rows:
        if not isinstance(entry, dict) or set(entry) - {"id", "version", "metadata"}:
            raise ValueError("Each flavor must be an object with id, version and optional metadata")
        flavor, version = entry.get("id"), entry.get("version")
        if not isinstance(flavor, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", flavor) or flavor in seen:
            raise ValueError(f"Invalid or duplicate flavor: {flavor!r}")
        seen.add(flavor)
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
            raise ValueError(f"Invalid game version for {flavor}: {version!r}")

        metadata = entry.get("metadata", {})
        if not isinstance(metadata, dict) or set(metadata) - {"curseforge"}:
            raise ValueError(f"Unsupported metadata for flavor {flavor}")
        curseforge = metadata.get("curseforge", {})
        if not isinstance(curseforge, dict) or set(curseforge) - {"versionType"}:
            raise ValueError(f"Unsupported CurseForge metadata for flavor {flavor}")
        version_type = curseforge.get("versionType", flavor)
        if not isinstance(version_type, str) or not version_type.strip() or version_type != version_type.strip():
            raise ValueError(f"Invalid CurseForge version type for flavor {flavor}")

        major, minor, patch = map(int, version.split("."))
        suffix = "" if flavor == "retail" else f"-{flavor}"
        matrix.append({
            "id": flavor,
            "version": version,
            "interface": major * 10000 + minor * 100 + patch,
            "asset": f"ArtisanLogbook-Bundle{suffix}-{addon_version}.zip",
            "curseforgeVersionType": version_type,
        })
    return {"include": matrix}


def main() -> None:
    config = yaml.safe_load(Path(".flavors.yml").read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        raise ValueError(".flavors.yml must contain a mapping")
    rendered = json.dumps(resolve_matrix(config, os.environ["VERSION"]), separators=(",", ":"))
    print(rendered)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={rendered}\n")


if __name__ == "__main__":
    main()
