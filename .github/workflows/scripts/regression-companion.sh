#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$root/src/companion"
for tool in dotnet node npm aspire; do
  command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 1; }
done

log="$(mktemp)"
trap 'rm -f -- "$log"' EXIT
echo "Restoring production build inputs"
dotnet restore ArtisanLogbook.Companion.slnx -p:CompanionWebDevelopment=false
echo "Checking incremental production restoration and assets"
node tools/smoke-incremental.mjs
echo "Checking real Aspire development startup and APIs"
(cd web && npm run test:development)
echo "Checking production restoration after Aspire's development install"
dotnet build src/WebAssets/WebAssets.csproj -c Release --no-restore \
  -p:CompanionWebDevelopment=false -warnaserror | tee "$log"
if ! grep -qi 'restoring with npm ci' "$log"; then
  echo "Production build did not restore after the development install." >&2
  exit 1
fi
echo "Companion extended regression checks passed."
