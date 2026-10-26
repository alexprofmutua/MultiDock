#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
sources=()
while IFS= read -r -d '' file; do sources+=("$file"); done < <(find MultiDock -name '*.swift' ! -name MultiDockApp.swift -print0)
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path)" \
  -module-cache-path build/ModuleCache -parse-as-library \
  "${sources[@]}" Scripts/WindowSmoke.swift Scripts/InteractionSmoke.swift Scripts/PreviewSmoke.swift Scripts/TestApplications.swift Scripts/QualitySmoke.swift Scripts/PolishSmoke.swift -o build/WindowSmoke
# Keep signed probe bundles out of synced Documents folders, which can reattach Finder metadata.
probe_root="$(mktemp -d "${TMPDIR:-/tmp}/MultiDock-probes.XXXXXX")"
trap 'rm -rf "$probe_root"' EXIT
mkdir -p "$probe_root/ActivityProbe.app/Contents/MacOS"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path build/ModuleCache \
  -parse-as-library Scripts/ActivityProbe.swift -o "$probe_root/ActivityProbe.app/Contents/MacOS/ActivityProbe"
cat > "$probe_root/ActivityProbe.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.multidock.tests.ActivityProbe</string>
<key>CFBundleExecutable</key><string>ActivityProbe</string>
<key>CFBundleName</key><string>MultiDock Activity Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>MultiDock test documents</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSItemContentTypes</key><array><string>public.plain-text</string><string>public.folder</string></array>
</dict></array>
</dict></plist>
PLIST
xattr -cr "$probe_root/ActivityProbe.app"
codesign --force --sign - "$probe_root/ActivityProbe.app"
mkdir -p "$probe_root/ActivityProbeAgent.app/Contents/MacOS"
cp "$probe_root/ActivityProbe.app/Contents/MacOS/ActivityProbe" "$probe_root/ActivityProbeAgent.app/Contents/MacOS/ActivityProbe"
cp "$probe_root/ActivityProbe.app/Contents/Info.plist" "$probe_root/ActivityProbeAgent.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string org.multidock.tests.ActivityProbe.Agent "$probe_root/ActivityProbeAgent.app/Contents/Info.plist"
plutil -insert LSUIElement -bool YES "$probe_root/ActivityProbeAgent.app/Contents/Info.plist"
xattr -cr "$probe_root/ActivityProbeAgent.app"
codesign --force --sign - "$probe_root/ActivityProbeAgent.app"
MULTIDOCK_ACTIVITY_PROBE="$probe_root/ActivityProbe.app" \
  MULTIDOCK_ACTIVITY_AGENT_PROBE="$probe_root/ActivityProbeAgent.app" build/WindowSmoke
