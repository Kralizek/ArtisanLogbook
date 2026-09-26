#!/usr/bin/env bash
set -euo pipefail

addon_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua5.1}"
command -v "$lua_bin" >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null

cd "$addon_root"
"$lua_bin" tests/trace_test.lua .
"$lua_bin" tests/adapter_test.lua .
"$lua_bin" tests/ledger_test.lua .

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/ArtisanLogbook" dist
cp ArtisanLogbook.toc "$staging/ArtisanLogbook/"
cp -R Capture Core Flavors Storage UI docs "$staging/ArtisanLogbook/"

pushd "$staging" >/dev/null
zip -qr ArtisanLogbook-ledger.zip ArtisanLogbook
unzip -tq ArtisanLogbook-ledger.zip
unzip -q ArtisanLogbook-ledger.zip -d extracted
popd >/dev/null

"$lua_bin" tests/addon_test.lua "$staging/extracted/ArtisanLogbook"
mv "$staging/ArtisanLogbook-ledger.zip" dist/ArtisanLogbook-ledger.zip
printf 'Package: %s/dist/ArtisanLogbook-ledger.zip\n' "$addon_root"
