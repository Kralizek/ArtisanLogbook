#!/usr/bin/env bash
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
required() { local name="$1"; [[ -n "${!name:-}" ]] || die "Missing $name"; }
asset_present() {
  gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' |
    grep -Fxq "$1"
}

case "${1:-}" in
  require-master)
    [[ "$GITHUB_REF" == refs/heads/master ]] || die "Releases must be dispatched from master."
    ;;
  resolve-channel)
    required CHANNEL
    if [[ "$CHANNEL" == stable ]]; then channel=''; else channel="$CHANNEL"; fi
    echo "channel=$channel" >> "$GITHUB_OUTPUT"
    ;;
  verify-version)
    # Usage: verify-version <command...>; the command must print exactly VERSION.
    required VERSION
    shift
    reported=$("$@" | tr -d '\r')
    [[ "$reported" == "$VERSION" ]] || die "Expected version $VERSION but '$*' reported '$reported'"
    ;;
  ensure-assets)
    required TAG; required VERSION; required GH_TOKEN; required ASSET_DIR
    shopt -s nullglob
    assets=("$ASSET_DIR"/*)
    ((${#assets[@]} > 0)) || die "No release assets found in $ASSET_DIR"
    for asset in "${assets[@]}"; do
      name="${asset##*/}"
      [[ "$name" == *"$VERSION"* ]] || die "Asset $name is not stamped with $VERSION"
      if asset_present "$name"; then
        echo "Preserving existing release asset $name"
      else
        gh release upload "$TAG" "$asset" --repo "$GITHUB_REPOSITORY"
      fi
    done
    ;;
  *)
    die "Usage: release-companion.sh {require-master|resolve-channel|verify-version|ensure-assets}"
    ;;
esac
