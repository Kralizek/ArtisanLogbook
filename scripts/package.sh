#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua5.1}"
command -v "$lua_bin" >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null

cd "$root"
"$lua_bin" tests/trace_test.lua
"$lua_bin" tests/adapter_test.lua

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
cp -R src/addon "$staging/ArtisanLogbook"
mkdir -p "$staging/ArtisanLogbook/docs" dist
cp docs/capture-tracer.md docs/implementation-plan.md "$staging/ArtisanLogbook/docs/"

pushd "$staging" >/dev/null
zip -qr ArtisanLogbook-tracer.zip ArtisanLogbook
unzip -tq ArtisanLogbook-tracer.zip
unzip -q ArtisanLogbook-tracer.zip -d extracted
popd >/dev/null

"$lua_bin" tests/addon_test.lua "$staging/extracted/ArtisanLogbook"
mv "$staging/ArtisanLogbook-tracer.zip" dist/ArtisanLogbook-tracer.zip
printf 'Package: %s/dist/ArtisanLogbook-tracer.zip\n' "$root"