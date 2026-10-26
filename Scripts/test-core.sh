#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$PWD/build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/ModuleCache"
options=(--disable-xctest --cache-path build/SwiftPMCache --config-path build/SwiftPMConfig
         --security-path build/SwiftPMSecurity --scratch-path build/PackageTests)
# Some Command Line Tools releases ship Testing outside SwiftPM's default search paths.
developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
if [[ "$developer" == */CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
  options+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
            -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib")
fi
swift test "${options[@]}" "$@"
