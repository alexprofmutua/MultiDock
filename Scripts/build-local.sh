#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Stage outside synced Documents folders, which can reattach Finder metadata after signing.
build_root="${MULTIDOCK_BUILD_DIR:-${TMPDIR:-/tmp}/MultiDock-local-build}"
mkdir -p "$build_root/MultiDock.app/Contents/MacOS" build/ModuleCache
sdk="$(xcrun --show-sdk-path)"
arch="${MULTIDOCK_ARCH:-$(uname -m)}"
case "$arch" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 1 ;; esac
optimization=(-Onone)
case "${MULTIDOCK_BUILD_CONFIGURATION:-Debug}" in
  Debug) ;;
  Release) optimization=(-O) ;;
  *) printf '%s\n' 'Build configuration must be Debug or Release.' >&2; exit 1 ;;
esac
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find MultiDock -name '*.swift' -print | LC_ALL=C sort)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "$arch-apple-macos14.0" -sdk "$sdk" \
  -module-cache-path build/ModuleCache -parse-as-library "${optimization[@]}" \
  "${sources[@]}" -o "$build_root/MultiDock.app/Contents/MacOS/MultiDock"
cp MultiDock/App/Info.plist "$build_root/MultiDock.app/Contents/Info.plist"
mkdir -p "$build_root/MultiDock.app/Contents/Resources"
cp MultiDock/Resources/AppIcon.icns "$build_root/MultiDock.app/Contents/Resources/AppIcon.icns"
xattr -cr "$build_root/MultiDock.app"
codesign --force --sign - --options runtime --timestamp=none "$build_root/MultiDock.app"
codesign --verify --strict "$build_root/MultiDock.app"
# Print only the path on stdout, for app_path="$(./Scripts/build-local.sh)".
printf '%s\n' "$build_root/MultiDock.app"
