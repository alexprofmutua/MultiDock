#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build and verify in nonsynced staging. The ZIP is the installable deliverable.
release_stage="$(mktemp -d "${TMPDIR:-/tmp}/MultiDock-release.XXXXXX")"
copy_path=""
previous_path=""
app_replaced=false
release_committed=false
cleanup() {
  if [[ "$release_committed" == false ]]; then
    if [[ "$app_replaced" == true && -e dist/MultiDock.app ]]; then rm -rf dist/MultiDock.app; fi
    if [[ -n "$previous_path" && -e "$previous_path" && ! -e dist/MultiDock.app ]]; then
      mv "$previous_path" dist/MultiDock.app
    fi
  fi
  if [[ -n "$copy_path" && -e "$copy_path" ]]; then rm -rf "$copy_path"; fi
  rm -rf "$release_stage"
}
trap cleanup EXIT
app_path="$(MULTIDOCK_BUILD_DIR="$release_stage" MULTIDOCK_ARCH=arm64 MULTIDOCK_BUILD_CONFIGURATION=Release ./Scripts/build-local.sh)"
mkdir -p dist
copy_path="$PWD/dist/.MultiDock-new-$$.app"
if [[ -e "$copy_path" ]]; then
  printf '%s\n' "Refusing to replace an existing staging path: $copy_path" >&2
  exit 1
fi
ditto "$app_path" "$copy_path"
xattr -cr "$copy_path"
# Synced copies can acquire FinderInfo even before the rename.
# build-local verified the source; the archive is independently verified below.
if [[ -e dist/MultiDock.app ]]; then
  previous_path="$release_stage/Previous-MultiDock.app"
  mv dist/MultiDock.app "$previous_path"
fi
mv "$copy_path" dist/MultiDock.app
app_replaced=true
# A Documents file provider may add FinderInfo immediately after the rename.
# Verify the clean source and re-extracted ZIP instead of treating metadata on
# the convenience loose copy as a compiler/signing failure.
version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
{
  printf 'MultiDock %s\nArchitecture: arm64\nMinimum macOS: 14.0\nConfiguration: Release (-O)\nSigning: ad hoc, hardened runtime\nNotarized: no\n' "$version"
  printf 'SDK: %s\n' "$(xcrun --show-sdk-version)"
  xcrun swiftc --version
} > dist/BUILD-INFO.txt
# Archive directly from clean staging; a synced dist directory can acquire FinderInfo after copying.
ditto -c -k --keepParent "$app_path" "$release_stage/MultiDock-arm64.zip"
mkdir "$release_stage/ArchiveCheck"
ditto -x -k "$release_stage/MultiDock-arm64.zip" "$release_stage/ArchiveCheck"
codesign --verify --strict "$release_stage/ArchiveCheck/MultiDock.app"
mv "$release_stage/MultiDock-arm64.zip" dist/MultiDock-arm64.zip
(cd dist && shasum -a 256 MultiDock-arm64.zip > SHA256SUMS)
release_committed=true
printf '%s\n' "$PWD/dist/MultiDock.app"
