#!/usr/bin/env bash
set -euo pipefail

addon_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua5.1}"
command -v "$lua_bin" >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null

core_root="$addon_root/src/ArtisanLogbook_Core"
ui_root="$addon_root/src/ArtisanLogbook"

cd "$addon_root"
"$lua_bin" tests/trace_test.lua "$core_root" "$addon_root/tests"
"$lua_bin" tests/adapter_test.lua "$core_root"
"$lua_bin" tests/ledger_test.lua "$core_root" "$addon_root/tests"
"$lua_bin" tests/api_test.lua "$core_root" "$addon_root/tests"

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/ArtisanLogbook" "$staging/ArtisanLogbook_Core" dist
cp -R "$core_root/". "$staging/ArtisanLogbook_Core/"
cp -R "$ui_root/". "$staging/ArtisanLogbook/"
test -f "$staging/ArtisanLogbook_Core/Core/API.lua"
test -f "$staging/ArtisanLogbook_Core/TraceWindow.lua"
test -f "$staging/ArtisanLogbook/UI/Window.lua"
test ! -e "$staging/ArtisanLogbook/Core"
test ! -e "$staging/ArtisanLogbook_Core/UI"
grep -q '^## SavedVariables: ArtisanLogbookDB, ArtisanLogbookTraceDB$' "$staging/ArtisanLogbook_Core/ArtisanLogbook_Core.toc"
grep -q '^## RequiredDeps: ArtisanLogbook_Core$' "$staging/ArtisanLogbook/ArtisanLogbook.toc"
grep -q '^## SavedVariables: ArtisanLogbookUISettings$' "$staging/ArtisanLogbook/ArtisanLogbook.toc"

"$lua_bin" tests/addon_test.lua "$staging/ArtisanLogbook_Core" "$staging/ArtisanLogbook"

pushd "$staging" >/dev/null
zip -qr ArtisanLogbook_Core.zip ArtisanLogbook_Core
zip -qr ArtisanLogbook.zip ArtisanLogbook
zip -qr ArtisanLogbook-Bundle.zip ArtisanLogbook_Core ArtisanLogbook
for archive in ArtisanLogbook_Core.zip ArtisanLogbook.zip ArtisanLogbook-Bundle.zip; do
	unzip -tq "$archive"
	case "$archive" in
		ArtisanLogbook_Core.zip) directories=(ArtisanLogbook_Core) ;;
		ArtisanLogbook.zip) directories=(ArtisanLogbook) ;;
		*) directories=(ArtisanLogbook_Core ArtisanLogbook) ;;
	esac
	diff -u <(find "${directories[@]}" -type f | sort) \
		<(unzip -Z -1 "$archive" | grep -v '/$' | sort)
done
popd >/dev/null

mv "$staging/"*.zip dist/
printf 'Packages: %s/dist/{ArtisanLogbook_Core,ArtisanLogbook,ArtisanLogbook-Bundle}.zip\n' "$addon_root"
