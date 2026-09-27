#!/usr/bin/env bash
set -euo pipefail

addon_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua5.1}"
command -v "$lua_bin" >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null

source_root="$addon_root/src/ArtisanLogbook"

cd "$addon_root"
"$lua_bin" tests/trace_test.lua "$source_root" "$addon_root/tests"
"$lua_bin" tests/adapter_test.lua "$source_root"
"$lua_bin" tests/ledger_test.lua "$source_root" "$addon_root/tests"
"$lua_bin" tests/api_test.lua "$source_root" "$addon_root/tests"

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/ArtisanLogbook" dist
cp "$source_root/ArtisanLogbook.toc" "$staging/ArtisanLogbook/"
cp -R "$source_root/Capture" "$source_root/Core" "$source_root/Flavors" "$source_root/Storage" "$source_root/UI" "$staging/ArtisanLogbook/"

pushd "$staging" >/dev/null
zip -qr ArtisanLogbook.zip ArtisanLogbook
unzip -tq ArtisanLogbook.zip
unzip -q ArtisanLogbook.zip -d extracted
popd >/dev/null

"$lua_bin" tests/addon_test.lua "$staging/extracted/ArtisanLogbook"
mv "$staging/ArtisanLogbook.zip" dist/ArtisanLogbook.zip
printf 'Package: %s/dist/ArtisanLogbook.zip\n' "$addon_root"
