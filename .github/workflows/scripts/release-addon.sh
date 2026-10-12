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
    for name in ArtisanLogbook_Core ArtisanLogbook ArtisanLogbook-Bundle; do
      mv "src/addon/dist/$name.zip" "src/addon/dist/$name-$VERSION.zip"
    done
    ;;
  ensure-assets)
    required TAG; required VERSION; required GH_TOKEN
    for name in "ArtisanLogbook_Core-$VERSION.zip" "ArtisanLogbook-$VERSION.zip" "ArtisanLogbook-Bundle-$VERSION.zip"; do
      if asset_present "$name"; then
        echo "Preserving existing release asset $name"
      else
        gh release upload "$TAG" "src/addon/dist/$name" --repo "$GITHUB_REPOSITORY"
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
    {
      echo 'notes<<ARTISAN_RELEASE_NOTES_EOF'
      cat authoritative/notes.md
      echo 'ARTISAN_RELEASE_NOTES_EOF'
    } >> "$GITHUB_OUTPUT"
    ;;
  check-curseforge)
    required TAG; required VERSION; required FLAVOR; required GAME_VERSION_ID
    required ASSET; required BUNDLE_SHA256; required PROJECT_ID; required API_TOKEN; required GH_TOKEN
    marker="curseforge-$FLAVOR-$VERSION.json"
    if asset_present "$marker"; then
      gh release download "$TAG" --repo "$GITHUB_REPOSITORY" --pattern "$marker" --dir authoritative
      jq -e --arg sha "$BUNDLE_SHA256" --arg project "$PROJECT_ID" \
        --arg flavor "$FLAVOR" --argjson gameVersionId "$GAME_VERSION_ID" --arg asset "$ASSET" \
        '.bundleSha256 == $sha and .projectId == $project and .flavor == $flavor and .gameVersionId == $gameVersionId and .asset == $asset' "authoritative/$marker" >/dev/null ||
        die "CurseForge marker conflicts with current bundle or project"
      echo "skip=true" >> "$GITHUB_OUTPUT"
      echo "CurseForge publication already recorded for $TAG."
    else
      echo "skip=false" >> "$GITHUB_OUTPUT"
      echo "::notice::No publication marker. Check CurseForge manually before retrying after an ambiguous upload failure."
    fi
    ;;
  record-curseforge)
    required TAG; required VERSION; required FLAVOR; required GAME_VERSION_ID
    required ASSET; required BUNDLE_SHA256; required PROJECT_ID; required GH_TOKEN
    jq -n --arg sha "$BUNDLE_SHA256" --arg project "$PROJECT_ID" \
      --arg flavor "$FLAVOR" --argjson gameVersionId "$GAME_VERSION_ID" --arg asset "$ASSET" \
      --arg tag "$TAG" \
      '{tag:$tag, projectId:$project, flavor:$flavor, gameVersionId:$gameVersionId, asset:$asset, bundleSha256:$sha}' > "authoritative/curseforge-$FLAVOR-$VERSION.json"
    gh release upload "$TAG" "authoritative/curseforge-$FLAVOR-$VERSION.json" --repo "$GITHUB_REPOSITORY"
    ;;
  *)
    die "Usage: release-addon.sh {require-master|resolve-channel|stamp|rename-artifacts|ensure-assets|download-bundle|check-curseforge|record-curseforge}"
    ;;
esac
