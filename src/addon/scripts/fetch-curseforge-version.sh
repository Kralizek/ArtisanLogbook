#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"

if [[ -f "$repo_root/.env" ]]; then
	set -a
	# shellcheck disable=SC1091
	. "$repo_root/.env"
	set +a
fi

usage() {
	printf 'Usage: bash %s <version> [flavor]\n' "${BASH_SOURCE[0]}" >&2
	printf 'Example: bash %s 12.1.5 retail\n' "${BASH_SOURCE[0]}" >&2
}

version="${1:-}"
flavor="${2:-retail}"
if [[ ! "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
	usage
	exit 2
fi

case "$flavor" in
	retail) game_version_type_id=517 ;;
	classic) game_version_type_id=67408 ;;
	bcc) game_version_type_id=73246 ;;
	wrath) game_version_type_id=73713 ;;
	cata) game_version_type_id=77522 ;;
	mists) game_version_type_id=79434 ;;
	titan) game_version_type_id=81212 ;;
	forever) game_version_type_id=88568 ;;
	*)
		printf 'Unsupported flavor: %s\n' "$flavor" >&2
		usage
		exit 2
		;;
esac

api_token="${CF_API_TOKEN:-${CURSE_FORGE_TOKEN:-}}"
if [[ -z "$api_token" ]]; then
	printf 'Set CF_API_TOKEN or CURSE_FORGE_TOKEN in the environment or repo .env.\n' >&2
	exit 2
fi
command -v curl >/dev/null
command -v jq >/dev/null

major=$((10#${BASH_REMATCH[1]}))
minor=$((10#${BASH_REMATCH[2]}))
patch=$((10#${BASH_REMATCH[3]}))
interface=$((major * 10000 + minor * 100 + patch))
versions=$(curl --fail --silent --show-error \
	--config <(printf 'header = "x-api-token: %s"\n' "$api_token") \
	'https://wow.curseforge.com/api/game/wow/versions')
matches=$(jq -c --arg version "$version" --argjson type "$game_version_type_id" \
	'[.[] | select(.gameVersionTypeID == $type and .name == $version)]' <<< "$versions")
if [[ "$(jq 'length' <<< "$matches")" != 1 ]]; then
	printf 'Expected one CurseForge %s version named %s; found %s.\n' \
		"$flavor" "$version" "$(jq 'length' <<< "$matches")" >&2
	exit 1
fi

game_version_id=$(jq -r '.[0].id' <<< "$matches")
printf '%s %s: id=%s interface=%s type=%s\n' \
	"$flavor" "$version" "$game_version_id" "$interface" "$game_version_type_id"