#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root"
for tool in git lua5.1 diff; do
  command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 1; }
done

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
for entry in \
  '8d9bb247aeba5133745f5c2f82b25bdfe5795385 pre21' \
  'b5e24c6947f26d4482025a4c31d18ac93d627fe8 outcome2'; do
  read -r revision variant <<< "$entry"
  source="$revision:src/addon/src/ArtisanLogbook_Core/Storage/Ledger.lua"
  if ! git cat-file -e "$source"; then
    echo "Missing historical ledger $revision; fetch the full repository history." >&2
    exit 1
  fi
  echo "Regenerating historical $variant fixture with $revision"
  git show "$source" > "$temporary/Ledger.lua"
  lua5.1 src/addon/tests/fixtures/legacy/generate.lua "$temporary/Ledger.lua" "$variant" \
    > "$temporary/$variant.lua"
  diff -u "src/addon/tests/fixtures/legacy/v1-$variant.lua" "$temporary/$variant.lua"
done
echo "Historical fixture provenance checks passed."
