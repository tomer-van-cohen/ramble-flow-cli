#!/bin/bash
# Assembles and signs Ramble Flow.app from built executables. Used by ./install.sh (and by the
# end-to-end test). Needs only the Command Line Tools.
#
#   scripts/make-app.sh --bin-dir DIR --output "PATH/Ramble Flow.app"
#                       [--entitlements FILE] [--test-hooks] [--test-home DIR] [--cache DIR]
#
# --test-home (test builds only): sandbox exceptions for that home's two data folders instead of
# the real home's (home-relative exceptions always mean the real home, whatever $HOME says).
#
# Layout:
#   Contents/MacOS/RambleFlow    sandboxed background executable (signed with the entitlements)
#   Contents/MacOS/ramble-flow   command-line tool, not sandboxed (signed without entitlements)
#   Contents/Resources/AppIcon.icns, LICENSE.txt, THIRD_PARTY_NOTICES.md
#
# Signing is ad hoc (no Apple account). The output is deterministic for the same inputs.
set -euo pipefail
cd "$(dirname "$0")/.."

bin_dir="" output="" entitlements="Resources/RambleFlow.entitlements" test_hooks=0 test_home="" cache=".build/app-cache"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) bin_dir="$2"; shift ;;
    --output) output="$2"; shift ;;
    --entitlements) entitlements="$2"; shift ;;
    --test-hooks) test_hooks=1 ;;
    --test-home) test_home="$2"; shift ;;
    --cache) cache="$2"; shift ;;
    *) echo "usage: scripts/make-app.sh --bin-dir DIR --output APP [--entitlements FILE] [--test-hooks] [--cache DIR]" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$bin_dir" && -n "$output" ]] || { echo "make-app.sh: --bin-dir and --output are required" >&2; exit 2; }
[[ "$output" == *.app ]] || { echo "make-app.sh: --output must end in .app" >&2; exit 2; }

identifier="io.github.tomer-van-cohen.ramble-flow-cli"
version="$(tr -d '[:space:]' < VERSION)"

[[ ! -e "$output" ]] || rm -r "$output"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$bin_dir/RambleFlow" "$output/Contents/MacOS/RambleFlow"
cp "$bin_dir/ramble-flow" "$output/Contents/MacOS/ramble-flow"

plist="$output/Contents/Info.plist"
cp Resources/Info.plist "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
if (( test_hooks )); then
  # Test builds get their own identity (sandbox container, grants) so they never share anything
  # with a real installation.
  identifier="$identifier.test"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" -c "Set :CFBundleName Ramble Flow Test" "$plist"
  # Plain HTTP only to the loopback mock provider of the end-to-end test.
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$plist"
fi

# The Ramble logo, rendered from its approved geometry (cached: rendering takes a few seconds).
mkdir -p "$cache"
icon_key="$(shasum -a 256 scripts/make-icon.swift | cut -c1-16)"
if [[ ! -f "$cache/AppIcon-$icon_key.icns" ]]; then
  rm -rf "$cache/AppIcon.iconset"
  swift scripts/make-icon.swift "$cache/AppIcon.iconset" >/dev/null 2>&1
  iconutil -c icns "$cache/AppIcon.iconset" -o "$cache/AppIcon-$icon_key.icns"
fi
cp "$cache/AppIcon-$icon_key.icns" "$output/Contents/Resources/AppIcon.icns"
cp LICENSE "$output/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$output/Contents/Resources/THIRD_PARTY_NOTICES.md"

for exe in "$output/Contents/MacOS/RambleFlow" "$output/Contents/MacOS/ramble-flow"; do
  # SwiftPM records the toolchain folder as a search path; nothing resolves through it (the Swift
  # runtime is part of macOS), so drop it.
  otool -l "$exe" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | while read -r rpath; do
    case "$rpath" in /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null ;; esac
  done
done
find "$output" -name .DS_Store -delete

if [[ -n "$test_home" ]]; then
  (( test_hooks )) || { echo "make-app.sh: --test-home needs --test-hooks" >&2; exit 2; }
  key='com\.apple\.security\.temporary-exception\.files'
  adjusted="$cache/test-entitlements.plist"
  cp "$entitlements" "$adjusted"
  plutil -remove "$key\.home-relative-path\.read-write" "$adjusted" 2>/dev/null || true
  plutil -insert "$key\.absolute-path\.read-write" -array "$adjusted" 2>/dev/null || true
  plutil -insert "$key\.absolute-path\.read-write" -string "$test_home/Library/Application Support/Ramble Flow CLI/" -append "$adjusted"
  plutil -insert "$key\.absolute-path\.read-write" -string "$test_home/Library/Logs/Ramble Flow CLI/" -append "$adjusted"
  entitlements="$adjusted"
fi

# The command-line tool first (nested code), without entitlements: it is not sandboxed.
codesign --force --sign - --identifier "$identifier.cli" "$output/Contents/MacOS/ramble-flow" >/dev/null 2>&1
# Then the app, with the sandbox entitlements and the hardened runtime.
codesign --force --sign - --options runtime --entitlements "$entitlements" "$output" >/dev/null 2>&1
codesign --verify --strict "$output"
