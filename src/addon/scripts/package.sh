#!/usr/bin/env bash
set -euo pipefail

addon_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lua_bin="${LUA_BIN:-lua5.1}"
command -v "$lua_bin" >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null
command -v python3 >/dev/null || { printf 'python3 is required to read .curseforge.yml.\n' >&2; exit 2; }
command -v jq >/dev/null || { printf 'jq is required to select the configured flavor.\n' >&2; exit 2; }

core_root="$addon_root/src/ArtisanLogbook_Core"
ui_root="$addon_root/src/ArtisanLogbook"
addon_flavor="${ADDON_FLAVOR:-retail}"
version_matrix="$(VERSION=local GITHUB_OUTPUT=/dev/null python3 "$addon_root/../../.github/workflows/scripts/resolve-curseforge-matrix.py")"
if ! addon_interface="$(jq -er --arg flavor "$addon_flavor" '.include[] | select(.name == $flavor) | .interface' <<< "$version_matrix")"; then
	printf 'Flavor %s is not configured in .curseforge.yml.\n' "$addon_flavor" >&2
	exit 2
fi
artifact_suffix="${ARTIFACT_SUFFIX:-}"
skip_tests="${SKIP_TESTS:-false}"

if [[ ! "$addon_interface" =~ ^[0-9]+$ ]]; then
	printf 'Invalid add-on interface: %s\n' "$addon_interface" >&2
	exit 2
fi
if [[ -n "$artifact_suffix" && ! "$artifact_suffix" =~ ^-[a-z][a-z0-9-]*$ ]]; then
	printf 'Invalid artifact suffix: %s\n' "$artifact_suffix" >&2
	exit 2
fi
if [[ "$skip_tests" != true && "$skip_tests" != false ]]; then
	printf 'SKIP_TESTS must be true or false.\n' >&2
	exit 2
fi

cd "$addon_root"
if [[ "$skip_tests" == false ]]; then
	"$lua_bin" tests/trace_test.lua "$core_root" "$addon_root/tests"
	"$lua_bin" tests/adapter_test.lua "$core_root"
	"$lua_bin" tests/ledger_test.lua "$core_root" "$addon_root/tests"
	"$lua_bin" tests/api_test.lua "$core_root" "$addon_root/tests"
fi

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/ArtisanLogbook" "$staging/ArtisanLogbook_Core" dist
cp -R "$core_root/". "$staging/ArtisanLogbook_Core/"
cp -R "$ui_root/". "$staging/ArtisanLogbook/"
for toc in \
	"$staging/ArtisanLogbook/ArtisanLogbook.toc" \
	"$staging/ArtisanLogbook_Core/ArtisanLogbook_Core.toc"; do
	sed -i "s/^## Interface: .*/## Interface: $addon_interface/" "$toc"
	grep -Fx "## Interface: $addon_interface" "$toc" >/dev/null
done
test -f "$staging/ArtisanLogbook_Core/Core/API.lua"
test -f "$staging/ArtisanLogbook_Core/TraceWindow.lua"
test -f "$staging/ArtisanLogbook/UI/Window.lua"
test ! -e "$staging/ArtisanLogbook/Core"
test ! -e "$staging/ArtisanLogbook_Core/UI"
grep -q '^## SavedVariables: ArtisanLogbookDB, ArtisanLogbookTraceDB$' "$staging/ArtisanLogbook_Core/ArtisanLogbook_Core.toc"
grep -q '^## RequiredDeps: ArtisanLogbook_Core$' "$staging/ArtisanLogbook/ArtisanLogbook.toc"
grep -q '^## SavedVariables: ArtisanLogbookUISettings$' "$staging/ArtisanLogbook/ArtisanLogbook.toc"

if [[ "$skip_tests" == false ]]; then
	"$lua_bin" tests/addon_test.lua "$staging/ArtisanLogbook_Core" "$staging/ArtisanLogbook"
fi

pushd "$staging" >/dev/null
zip -qr "ArtisanLogbook_Core${artifact_suffix}.zip" ArtisanLogbook_Core
zip -qr "ArtisanLogbook${artifact_suffix}.zip" ArtisanLogbook
zip -qr "ArtisanLogbook-Bundle${artifact_suffix}.zip" ArtisanLogbook_Core ArtisanLogbook
for archive in ArtisanLogbook*.zip; do
	unzip -tq "$archive"
	case "$archive" in
		ArtisanLogbook_Core*.zip) directories=(ArtisanLogbook_Core) ;;
		ArtisanLogbook-Bundle*.zip) directories=(ArtisanLogbook_Core ArtisanLogbook) ;;
		ArtisanLogbook*.zip) directories=(ArtisanLogbook) ;;
		*) exit 1 ;;
	esac
	diff -u <(find "${directories[@]}" -type f | sort) \
		<(unzip -Z -1 "$archive" | grep -v '/$' | sort)
done
popd >/dev/null

mv "$staging/"*.zip dist/
printf 'Packages: %s/dist/ArtisanLogbook*%s.zip\n' "$addon_root" "$artifact_suffix"
