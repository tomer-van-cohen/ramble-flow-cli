#!/bin/bash
# Ramble Flow (command line): install, change settings, or uninstall.
#
#   ./install.sh               build, install and set up (rerun it any time to change settings)
#   ./install.sh --uninstall   stop the background process and remove it (asks about settings and
#                              history; never touches recordings or transcripts)
#   ./install.sh --help
#
# Needs only Apple's Command Line Tools (Swift). No sudo, Xcode, Homebrew, Node, Python or ffmpeg.
# Everything it installs is in your home folder:
#   ~/.local/bin/ramble-flow                                   the program
#   ~/Library/LaunchAgents/<label>.plist                        starts it at login
#   ~/Library/Application Support/Ramble Flow CLI/              settings, API key file, job state
#   ~/Library/Logs/Ramble Flow CLI/                             logs
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
tilde() { local p="$1"; if [[ "$p" == "$HOME"/* ]]; then p="~${p#"$HOME"}"; fi; printf '%s' "$p"; }

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

mode=install
purge=ask
assume_yes=0
setup_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) mode=uninstall ;;
    --purge) purge=yes ;;
    --keep-data) purge=no ;;
    --yes|-y) assume_yes=1 ;;
    --skip-key-check) setup_args+=(--skip-key-check) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(id -u)" != 0 ]] || fail "run this as yourself, not with sudo: everything is installed in your home folder."
[[ -n "${HOME:-}" && -d "$HOME" ]] || fail "HOME is not set."

label="${RAMBLE_FLOW_LABEL:-io.github.tomer-van-cohen.ramble-flow-cli}"
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "invalid RAMBLE_FLOW_LABEL"
test_hooks="${RAMBLE_FLOW_TEST_HOOKS:-0}"
if [[ "$test_hooks" == 1 && "$label" != *.test* ]]; then
  fail "RAMBLE_FLOW_TEST_HOOKS=1 builds a development variant; it needs a RAMBLE_FLOW_LABEL containing .test"
fi

# ---------------------------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------------------------
uninstall() {
  local bin_dir="${RAMBLE_FLOW_BIN_DIR:-$HOME/.local/bin}"
  bin_dir="${bin_dir/#\~/$HOME}"
  local binary="$bin_dir/ramble-flow"
  local support="$HOME/Library/Application Support/Ramble Flow CLI"
  local logs="$HOME/Library/Logs/Ramble Flow CLI"
  local plist="$HOME/Library/LaunchAgents/$label.plist"
  local domain="gui/$(id -u)"
  local transcripts=""
  if [[ -f "$support/config.json" ]]; then
    transcripts="$(plutil -extract destinationPath raw -o - "$support/config.json" 2>/dev/null || true)"
  fi

  say "Ramble Flow — uninstall"
  say "  Stops and removes:  the background process ($label)"
  say "                      $(tilde "$plist")"
  say "                      $(tilde "$binary")"
  say "                      $(tilde "$support")/secrets.env (your API key)"
  say "  Never touched:      your Voice Memos and your transcripts${transcripts:+ ($(tilde "$transcripts"))}"
  if (( ! assume_yes )); then
    read -r -p "Uninstall? [Y/n]: " answer || answer=n
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]] || { say "Nothing was changed."; exit 1; }
  fi

  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchctl bootout "$domain/$label.access-probe" >/dev/null 2>&1 || true
  # bootout returns before launchd has finished; wait until the job is really gone.
  for _ in $(seq 1 40); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || break
    sleep 0.25
  done
  launchctl print "$domain/$label" >/dev/null 2>&1 && say "  warning: launchd still lists $label; it is removed at the next login."
  rm -f "$plist"
  rm -f "$binary"
  rm -f "$support/secrets.env" "$support/access-probe.plist" "$support/access-probe.json"
  say "  Removed the background process, its LaunchAgent, the program and the API key file."

  local remove_data="$purge"
  if [[ "$remove_data" == ask ]]; then
    if (( assume_yes )); then
      remove_data=no
    else
      say ""
      say "  Settings, job history (including the new-recordings cutoff) and logs are still in:"
      say "    $(tilde "$support")"
      say "    $(tilde "$logs")"
      say "  Keep them to pick up where you left off if you install again."
      read -r -p "  Delete them too? [y/N]: " answer || answer=n
      [[ "$answer" =~ ^[Yy] ]] && remove_data=yes || remove_data=no
    fi
  fi
  if [[ "$remove_data" == yes ]]; then
    case "$support" in "$HOME/Library/Application Support/Ramble Flow CLI") rm -rf "$support" ;; esac
    case "$logs" in "$HOME/Library/Logs/Ramble Flow CLI") rm -rf "$logs" ;; esac
    say "  Deleted settings, job history and logs."
  else
    say "  Kept settings, job history and logs."
  fi
  say ""
  say "Last step, by hand: macOS keeps the ramble-flow entry in System Settings › Privacy & Security ›"
  say "Full Disk Access until you select it and click −. Open that list with:"
  say "  open \"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles\""
  say "Your recordings and transcripts were not touched."
}

if [[ "$mode" == uninstall ]]; then
  uninstall
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------
say "Ramble Flow — install"
macos="$(sw_vers -productVersion)"
[[ "${macos%%.*}" -ge 14 ]] || fail "macOS 14 or later is needed (this Mac runs $macos)."
if [[ "$(uname -m)" != arm64 ]]; then
  say "warning: only Apple silicon Macs have been tested; continuing on $(uname -m)."
fi
if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  fail "Apple's Command Line Tools are missing. Run:
    xcode-select --install
  finish Apple's installer, then run ./install.sh again."
fi
swift_version="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)"
[[ -n "$swift_version" ]] || fail "could not determine the Swift version."
major="${swift_version%%.*}"; minor="${swift_version#*.}"
if (( major < 5 || (major == 5 && minor < 10) )); then
  fail "Swift 5.10 or later is needed (found $swift_version). Update the Command Line Tools (Software Update)."
fi
command -v codesign >/dev/null 2>&1 || fail "codesign is missing (part of the Command Line Tools)."

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------
build_path=".build"
flags=()
if [[ "$test_hooks" == 1 ]]; then
  build_path=".build/test-hooks"
  flags=(-Xswiftc -DRAMBLE_FLOW_TEST_HOOKS)
  say "  (development build with loopback test hooks, label $label)"
fi
mkdir -p "$build_path"
build_log="$build_path/install-build.log"
say "  Building with Swift $swift_version (the first build takes a minute or two)…"
if ! swift build -c release --product ramble-flow --build-path "$build_path" ${flags[@]+"${flags[@]}"} >"$build_log" 2>&1; then
  tail -40 "$build_log" >&2
  fail "the build failed (full log: $build_log)."
fi
bin_path="$(swift build -c release --build-path "$build_path" --show-bin-path 2>/dev/null)"
staging="$build_path/install-staging"
rm -rf "$staging"; mkdir -p "$staging"
staged="$staging/ramble-flow"
cp "$bin_path/ramble-flow" "$staged"
# SwiftPM records the toolchain folder as a search path; nothing resolves through it (the Swift
# runtime is part of macOS), so drop it.
otool -l "$staged" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | while read -r rpath; do
  case "$rpath" in /Library/Developer/*|/Applications/Xcode*) install_name_tool -delete_rpath "$rpath" "$staged" 2>/dev/null ;; esac
done
# Ad-hoc signature with a fixed identifier. Deterministic: the same checkout gives the same
# bytes, so rerunning this script does not disturb macOS permissions granted to the program.
codesign --force --sign - --identifier io.github.tomer-van-cohen.ramble-flow-cli "$staged" >/dev/null 2>&1 \
  || fail "could not sign the program locally."

# Where everything goes (computed by the program itself, so script and program always agree).
eval "$("$staged" paths)"

# ---------------------------------------------------------------------------------------------
# Install the program (only when it changed)
# ---------------------------------------------------------------------------------------------
# macOS ties Full Disk Access to the exact program bytes (ad-hoc signature). The program is only
# replaced when it really changed: same bytes, or built from the same sources with the same Swift
# (a clean rebuild is not always byte-identical) means the installed copy is kept.
source_fingerprint="$( { swift --version 2>/dev/null; echo "hooks=$test_hooks"; cat Package.swift; \
  find Sources -type f -name '*.swift' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1)"
build_record="$RF_SUPPORT/installed-build"
installed_matches() {
  [[ -f "$RF_BINARY" ]] || return 1
  cmp -s "$staged" "$RF_BINARY" && return 0
  [[ -f "$build_record" ]] || return 1
  local recorded_source recorded_binary
  recorded_source="$(sed -n 's/^source=//p' "$build_record")"
  recorded_binary="$(sed -n 's/^binary=//p' "$build_record")"
  [[ "$recorded_source" == "$source_fingerprint" && "$recorded_binary" == "$(shasum -a 256 "$RF_BINARY" | cut -d' ' -f1)" ]]
}
record_build() {
  mkdir -p "$RF_SUPPORT" && chmod 700 "$RF_SUPPORT"
  printf 'source=%s\nbinary=%s\n' "$source_fingerprint" "$(shasum -a 256 "$RF_BINARY" | cut -d' ' -f1)" > "$build_record"
}

changed_flag=()
if installed_matches; then
  say "  Program unchanged: $(tilde "$RF_BINARY") (macOS permissions stay valid)"
  record_build
else
  if [[ -f "$RF_BINARY" ]]; then
    say "  This checkout builds a new version of the program. Stopping the background process to replace it."
    launchctl bootout "gui/$(id -u)/$RF_LABEL" >/dev/null 2>&1 || true
    changed_flag=(--binary-changed)
  fi
  mkdir -p "$(dirname "$RF_BINARY")"
  tmp="$RF_BINARY.installing.$$"
  cp "$staged" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$RF_BINARY"
  codesign --verify --strict "$RF_BINARY" >/dev/null 2>&1 || fail "the installed program's signature did not verify."
  record_build
  say "  Installed $(tilde "$RF_BINARY")"
fi
case ":$PATH:" in
  *":$(dirname "$RF_BINARY"):"*) ;;
  *) say "  Tip: $(tilde "$(dirname "$RF_BINARY")") is not on your PATH; use the full path, or add it to PATH." ;;
esac

# The questions, the permission check and starting the background process happen in the program.
exec "$RF_BINARY" setup ${changed_flag[@]+"${changed_flag[@]}"} ${setup_args[@]+"${setup_args[@]}"}
