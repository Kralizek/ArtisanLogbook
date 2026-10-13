#!/usr/bin/env bash
set -euo pipefail

archive="${1:?Usage: validate-addon-bundle.sh <bundle.zip>}"
[[ -s "$archive" ]] || { echo "::error::Missing or empty bundle: $archive" >&2; exit 1; }
unzip -tq "$archive"

# The upload must contain the two addon directories, not loose files,
# nested ZIP packages, or the GitHub Actions aggregate artifact.
entries="$(unzip -Z -1 "$archive")"
[[ -n "$entries" ]] || { echo "::error::Empty addon bundle" >&2; exit 1; }
while IFS= read -r entry; do
  case "$entry" in
    ArtisanLogbook/*|ArtisanLogbook_Core/*) ;;
    *) echo "::error::Unexpected archive entry: $entry" >&2; exit 1 ;;
  esac
  case "${entry,,}" in
    *.zip) echo "::error::Nested ZIP archive in bundle: $entry" >&2; exit 1 ;;
  esac
done <<< "$entries"

for addon in ArtisanLogbook ArtisanLogbook_Core; do
  grep -Fxq "$addon/$addon.toc" <<< "$entries" || {
    echo "::error::Missing $addon/$addon.toc" >&2
    exit 1
  }
done
