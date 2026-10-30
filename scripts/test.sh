#!/bin/bash
# Runs the test suite. Works with full Xcode or with only the Command Line Tools: the CLT ship
# Swift Testing but SwiftPM does not find it on its own, so its location is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
developer_dir="$(xcode-select -p 2>/dev/null || true)"
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ "$developer_dir" == */CommandLineTools && -d "$frameworks/Testing.framework" ]]; then
  libs="$developer_dir/Library/Developer/usr/lib"
  args+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks"
         -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
