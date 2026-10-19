#!/usr/bin/env bash
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }
required() { local name="$1"; [[ -n "${!name:-}" ]] || die "Missing $name"; }
asset_present() {
  gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' |
    grep -Fxq "$1"
}
toc_paths=(src/addon/src/ArtisanLogbook/ArtisanLogbook.toc src/addon/src/ArtisanLogbook_Core/ArtisanLogbook_Core.toc)

case "${1:-}" in
  require-master)
    [[ "$GITHUB_REF" == refs/heads/master ]] || die "Releases must be dispatched from master."
    ;;
  resolve-channel)
    required CHANNEL
    if [[ "$CHANNEL" == stable ]]; then channel=''; else channel="$CHANNEL"; fi
    echo "channel=$channel" >> "$GITHUB_OUTPUT"
    ;;
  stamp)
    required VERSION; required RELEASE_TAG
    for toc in "${toc_paths[@]}"; do
      sed -i "s/^## Version: .*/## Version: $VERSION/" "$toc"
      sed -i "s/^## X-Release-Tag: .*/## X-Release-Tag: $RELEASE_TAG/" "$toc"
      grep -Fx "## Version: $VERSION" "$toc"
      grep -Fx "## X-Release-Tag: $RELEASE_TAG" "$toc"
    done
    ;;
  rename-artifacts)
    required VERSION
    shopt -s nullglob
    archives=(src/addon/dist/*.zip)
    ((${#archives[@]} > 0)) || die "No packaged archives found"
    for archive in "${archives[@]}"; do
      mv "$archive" "${archive%.zip}-$VERSION.zip"
    done
    ;;
  ensure-assets)
    required TAG; required VERSION; required GH_TOKEN
    shopt -s nullglob
    archives=(src/addon/dist/*.zip)
    ((${#archives[@]} > 0)) || die "No packaged release archives found"
    for archive in "${archives[@]}"; do
      name="${archive##*/}"
      if asset_present "$name"; then
        echo "Preserving existing release asset $name"
      else
        gh release upload "$TAG" "$archive" --repo "$GITHUB_REPOSITORY"
      fi
    done
    ;;
  download-bundle)
    required TAG; required ASSET; required INTERFACE; required GH_TOKEN
    mkdir -p authoritative
    gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern "$ASSET" --dir authoritative
    bundle="authoritative/$ASSET"
    [[ -s "$bundle" ]] || die "Missing bundle $ASSET"
    unzip -tq "$bundle"
    for addon in ArtisanLogbook ArtisanLogbook_Core; do
      unzip -p "$bundle" "$addon/$addon.toc" | grep -Fx "## X-Release-Tag: $TAG"
      unzip -p "$bundle" "$addon/$addon.toc" | grep -Fx "## Interface: $INTERFACE"
    done
    gh release view "$TAG" --repo "$GITHUB_REPOSITORY" --json body --jq '.body' > authoritative/notes.md
    digest=$(sha256sum "$bundle" | cut -d' ' -f1)
    echo "digest=$digest" >> "$GITHUB_OUTPUT"
    # GitHub Actions multiline outputs require a delimiter absent from the content.
    delimiter="ARTISAN_NOTES_$(cat /proc/sys/kernel/random/uuid)"
    while grep -Fxq "$delimiter" authoritative/notes.md; do
      delimiter="ARTISAN_NOTES_$(cat /proc/sys/kernel/random/uuid)"
    done
    {
      printf 'notes<<%s\n' "$delimiter"
      cat authoritative/notes.md
      printf '\n%s\n' "$delimiter"
    } >> "$GITHUB_OUTPUT"
    ;;
  check-curseforge)
    required TAG; required VERSION; required FLAVOR; required GAME_VERSION; required VERSION_TYPE
    required ASSET; required BUNDLE_SHA256; required PROJECT_ID; required GH_TOKEN
    marker="curseforge-$FLAVOR-$VERSION.json"
    if asset_present "$marker"; then
      gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern "$marker" --dir authoritative
      jq -e --arg sha "$BUNDLE_SHA256" --arg project "$PROJECT_ID" \
        --arg flavor "$FLAVOR" --arg gameVersion "$GAME_VERSION" --arg versionType "$VERSION_TYPE" \
        --arg asset "$ASSET" --arg tag "$TAG" \
        '.tag == $tag and .bundleSha256 == $sha and .projectId == $project and
         .flavor == $flavor and .gameVersion == $gameVersion and
         .versionType == $versionType and .asset == $asset and
         (.gameVersions | type == "array" and length == 1 and
           .[0].version == $gameVersion and .[0].type == $versionType and
           (.[0].versionId | type == "number" and . > 0 and . == floor)) and
         (.fileId | type == "number" and . > 0 and . == floor)' "authoritative/$marker" >/dev/null ||
        die "CurseForge marker conflicts with current bundle, version selector, or project"
      echo "skip=true" >> "$GITHUB_OUTPUT"
      echo "CurseForge publication already recorded for $TAG."
    else
      if [[ "${GITHUB_RUN_ATTEMPT:-1}" =~ ^[1-9][0-9]*$ ]] && (( GITHUB_RUN_ATTEMPT > 1 )); then
        die "CurseForge marker missing on workflow rerun. Check CurseForge for an earlier successful upload before starting a new release run."
      fi
      echo "skip=false" >> "$GITHUB_OUTPUT"
      echo "::notice::No publication marker. A separate new workflow run cannot be distinguished from a first publication."
    fi
    ;;
  record-curseforge)
    required TAG; required VERSION; required FLAVOR; required GAME_VERSION; required VERSION_TYPE
    required ASSET; required BUNDLE_SHA256; required PROJECT_ID; required GH_TOKEN
    required RESOLVED_GAME_VERSIONS; required PUBLISHED_FILE_ID
    [[ "$PUBLISHED_FILE_ID" =~ ^[1-9][0-9]*$ ]] || die "Missing or invalid CurseForge published file ID"
    jq -e --arg version "$GAME_VERSION" --arg versionType "$VERSION_TYPE" \
      'type == "array" and length == 1 and .[0].version == $version and
       .[0].type == $versionType and (.[0].versionId | type == "number" and . > 0 and . == floor)' \
       <<< "$RESOLVED_GAME_VERSIONS" >/dev/null ||
      die "CurseForge publisher returned invalid game-versions output"
    jq -n --arg sha "$BUNDLE_SHA256" --arg project "$PROJECT_ID" \
      --arg flavor "$FLAVOR" --arg gameVersion "$GAME_VERSION" --arg versionType "$VERSION_TYPE" \
      --arg asset "$ASSET" --arg tag "$TAG" --argjson fileId "$PUBLISHED_FILE_ID" \
      --argjson gameVersions "$RESOLVED_GAME_VERSIONS" \
      '{tag:$tag, projectId:$project, flavor:$flavor, gameVersion:$gameVersion,
        versionType:$versionType, gameVersions:$gameVersions, fileId:$fileId,
        asset:$asset, bundleSha256:$sha}' > "authoritative/curseforge-$FLAVOR-$VERSION.json"
    gh release upload "$TAG" "authoritative/curseforge-$FLAVOR-$VERSION.json" --repo "$GITHUB_REPOSITORY"
    ;;
  *)
    die "Usage: release-addon.sh {require-master|resolve-channel|stamp|rename-artifacts|ensure-assets|download-bundle|check-curseforge|record-curseforge}"
    ;;
esac
