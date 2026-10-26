#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_path="${1:-$PWD/dist/MultiDock.app}"
mkdir -p build/ModuleCache build/Measurements
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(find MultiDock -name '*.swift' ! -name MultiDockApp.swift -print | LC_ALL=C sort)
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" -module-cache-path build/ModuleCache \
  -parse-as-library "${sources[@]}" Scripts/TestApplications.swift Scripts/PerformanceProbe.swift -o build/PerformanceProbe
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -target arm64-apple-macos14.0 -module-cache-path build/ModuleCache \
  -parse-as-library Scripts/StartupProbe.swift -o build/StartupProbe
build/StartupProbe "$app_path" > build/Measurements/startup.json
build/PerformanceProbe > build/Measurements/performance.json
printf '%s\n' "$PWD/build/Measurements"
