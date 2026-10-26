#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --check ) ]]; then
  printf '%s\n' 'Usage: Scripts/install-local.sh [--check]' >&2
  exit 1
fi
install_stage="$(mktemp -d "${TMPDIR:-/tmp}/MultiDock-install.XXXXXX")"
install_target="$HOME/Applications/MultiDock.app"
candidate_path=""
previous_path=""
replacement_started=false
committed=false
cleanup() {
  if [[ "$committed" == false ]]; then
    if [[ "$replacement_started" == true && -e "$install_target" ]]; then rm -rf "$install_target"; fi
    if [[ -n "$previous_path" && -e "$previous_path" && ! -e "$install_target" ]]; then mv "$previous_path" "$install_target"; fi
  fi
  if [[ -n "$candidate_path" && -e "$candidate_path" ]]; then rm -rf "$candidate_path"; fi
  rm -rf "$install_stage"
}
trap cleanup EXIT
ditto -x -k dist/MultiDock-arm64.zip "$install_stage"
codesign --verify --strict "$install_stage/MultiDock.app"
version="$(plutil -extract CFBundleShortVersionString raw "$install_stage/MultiDock.app/Contents/Info.plist")"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$install_stage/ModuleCache" -parse-as-library \
  Scripts/QuitInstalled.swift -o "$install_stage/QuitInstalled"
if [[ "${1:-}" == --check ]]; then
  "$install_stage/QuitInstalled" --check
  printf 'Verified MultiDock %s archive and compiled installer helper. No installation was performed.\n' "$version"
  exit 0
fi
if [[ -L "$install_target" ]]; then
  printf '%s\n' 'Refusing to replace an application symlink. Choose a regular application destination first.' >&2
  exit 1
fi
mkdir -p "$HOME/Applications"
proposed_path="$HOME/Applications/.MultiDock-install-$$.app"
if [[ -e "$proposed_path" ]]; then printf '%s\n' 'An installation staging path already exists.' >&2; exit 1; fi
candidate_path="$proposed_path"
ditto "$install_stage/MultiDock.app" "$candidate_path"
xattr -cr "$candidate_path"
codesign --verify --strict "$candidate_path"
# No force quit or process killing: configuration saves finish through normal app termination.
"$install_stage/QuitInstalled"
if [[ -e "$install_target" ]]; then
  previous_path="$install_stage/Previous.app"
  mv "$install_target" "$previous_path"
fi
replacement_started=true
mv "$candidate_path" "$install_target"
codesign --verify --strict "$install_target"
open "$install_target"
committed=true
printf 'Installed and opened MultiDock %s in %s. Saved dock settings were retained.\n' "$version" "$install_target"
