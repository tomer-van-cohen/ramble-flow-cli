#!/bin/bash
# Ramble Flow: install, change settings, check status, or uninstall. Everything in the terminal.
#
#   ./install.sh               build, install and set up (rerun it any time to change settings)
#   ./install.sh --status      what the background app is doing
#   ./install.sh --uninstall   stop and remove Ramble Flow (asks about settings and history;
#                              never touches recordings or transcripts)
#   ./install.sh --help
#
# Needs only Apple's Command Line Tools (Swift). No sudo, Xcode, Homebrew, Node, Python or ffmpeg.
# Everything it installs is in your home folder:
#   ~/Applications/Ramble Flow.app                      the background app (no windows, no icons)
#   ~/Library/LaunchAgents/<label>.plist                 starts it at login
#   ~/Library/Application Support/Ramble Flow CLI/       settings, API key file, folder grants, jobs
#   ~/Library/Logs/Ramble Flow CLI/                      logs
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
tilde() { local p="$1"; if [[ "$p" == "$HOME"/* ]]; then p="~${p#"$HOME"}"; fi; printf '%s' "$p"; }

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

mode=install
purge=ask
assume_yes=0
setup_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) mode=uninstall ;;
    --status) mode=status ;;
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

release_id="io.github.tomer-van-cohen.ramble-flow-cli"
bundle_id="$release_id"
[[ "${RAMBLE_FLOW_TEST_HOOKS:-0}" == 1 ]] && bundle_id="$release_id.test"
label="${RAMBLE_FLOW_LABEL:-$release_id}"
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "invalid RAMBLE_FLOW_LABEL"
test_hooks="${RAMBLE_FLOW_TEST_HOOKS:-0}"
if [[ "$test_hooks" == 1 && "$label" != *.test* ]]; then
  fail "RAMBLE_FLOW_TEST_HOOKS=1 builds a development variant; it needs a RAMBLE_FLOW_LABEL containing .test"
fi
app_dir="${RAMBLE_FLOW_APP_DIR:-$HOME/Applications}"
app_dir="${app_dir/#\~/$HOME}"
app="$app_dir/Ramble Flow.app"
support="$HOME/Library/Application Support/Ramble Flow CLI"
logs="$HOME/Library/Logs/Ramble Flow CLI"
plist="$HOME/Library/LaunchAgents/$label.plist"
container="$HOME/Library/Containers/$bundle_id"
domain="gui/$(id -u)"
# Where the first, Full-Disk-Access-based version put its program.
old_cli="$HOME/.local/bin/ramble-flow"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

bundle_id_of() { plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true; }
is_ours() { [[ -d "$1" && "$(bundle_id_of "$1")" == "$bundle_id" ]]; }
signing_id_of() { codesign -dv "$1" 2>&1 | sed -n 's/^Identifier=//p'; }

stop_agent() {
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  # bootout returns before launchd has finished; wait until the job is really gone.
  for _ in $(seq 1 40); do
    launchctl print "$domain/$label" >/dev/null 2>&1 || return 0
    sleep 0.25
  done
}

remove_old_cli() {
  if [[ -f "$old_cli" && "$(signing_id_of "$old_cli")" == "$release_id" ]]; then
    rm -f "$old_cli"
    rm -f "$support/installed-build"
    say "  Removed the earlier command-line program $(tilde "$old_cli") (settings and key are kept)."
  fi
}

# ---------------------------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------------------------
if [[ "$mode" == status ]]; then
  [[ -x "$app/Contents/MacOS/ramble-flow" ]] || { say "Ramble Flow is not installed (no $(tilde "$app"))."; exit 1; }
  exec "$app/Contents/MacOS/ramble-flow" status
fi

# ---------------------------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------------------------
uninstall() {
  local transcripts=""
  if [[ -f "$support/config.json" ]]; then
    transcripts="$(plutil -extract destinationPath raw -o - "$support/config.json" 2>/dev/null || true)"
  fi
  say "Ramble Flow — uninstall"
  say "  Stops and removes:  the background app ($label)"
  say "                      $(tilde "$plist")"
  say "                      $(tilde "$app")"
  say "                      $(tilde "$support")/secrets.env (your API key) and grants.json (folder grants)"
  say "  Never touched:      your Voice Memos and your transcripts${transcripts:+ ($(tilde "$transcripts"))}"
  if (( ! assume_yes )); then
    read -r -p "Uninstall? [Y/n]: " answer || answer=n
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]] || { say "Nothing was changed."; exit 1; }
  fi

  stop_agent
  launchctl bootout "$domain/$label.access-probe" >/dev/null 2>&1 || true
  launchctl print "$domain/$label" >/dev/null 2>&1 && say "  warning: launchd still lists $label; it goes away at the next login."
  rm -f "$plist"
  if is_ours "$app"; then
    "$lsregister" -u "$app" >/dev/null 2>&1 || true
    rm -r "$app"
  elif [[ -e "$app" ]]; then
    say "  Left $(tilde "$app") alone: it is a different app ($(bundle_id_of "$app"))."
  fi
  remove_old_cli
  rm -f "$support/secrets.env" "$support/grants.json" "$support/grant-result.json" "$support/access-probe.plist" "$support/access-probe.json"
  say "  Removed the background app, its LaunchAgent, the API key file and the folder grants."

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
    if [[ "$support" == "$HOME/Library/Application Support/Ramble Flow CLI" && -d "$support" ]]; then rm -r "$support"; fi
    if [[ "$logs" == "$HOME/Library/Logs/Ramble Flow CLI" && -d "$logs" ]]; then rm -r "$logs"; fi
    say "  Deleted settings, job history and logs."
    if [[ -d "$container" ]]; then
      say "  macOS keeps the app's sandbox container (temporary files only) and does not let scripts delete"
      say "  it: $(tilde "$container"). Drag it to the Trash in Finder if you want it gone."
    fi
  else
    say "  Kept settings, job history and logs."
  fi
  say ""
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
for tool in codesign iconutil ditto plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"
done
if [[ -e "$app" ]] && ! is_ours "$app"; then
  fail "$(tilde "$app") already exists and is a different app ($(bundle_id_of "$app")).
  This installer never replaces it. Quit that app, move it elsewhere (or delete it), then run
  ./install.sh again. To install somewhere else instead: RAMBLE_FLOW_APP_DIR=<folder> ./install.sh"
fi

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------
build_path=".build"
flags=()
app_flags=()
if [[ "$test_hooks" == 1 ]]; then
  build_path=".build/test-hooks"
  flags=(-Xswiftc -DRAMBLE_FLOW_TEST_HOOKS)
  app_flags=(--test-hooks --test-home "$HOME")
  say "  (development build with loopback test hooks, label $label)"
fi
mkdir -p "$build_path"
build_log="$build_path/install-build.log"
say "  Building with Swift $swift_version (the first build takes a minute or two)…"
: > "$build_log"
for product in ramble-flow RambleFlow; do
  if ! swift build -c release --product "$product" --build-path "$build_path" ${flags[@]+"${flags[@]}"} >>"$build_log" 2>&1; then
    tail -40 "$build_log" >&2
    fail "the build failed (full log: $build_log)."
  fi
done
bin_path="$(swift build -c release --build-path "$build_path" --show-bin-path 2>/dev/null)"
staged="$build_path/install-staging/Ramble Flow.app"
mkdir -p "$build_path/install-staging"
scripts/make-app.sh --bin-dir "$bin_path" --output "$staged" ${app_flags[@]+"${app_flags[@]}"} >>"$build_log" 2>&1 \
  || { tail -20 "$build_log" >&2; fail "could not assemble or sign the app (log: $build_log)."; }

# Where everything goes (computed by the program itself, so script and program always agree).
eval "$(RAMBLE_FLOW_APP_DIR="$app_dir" "$staged/Contents/MacOS/ramble-flow" paths)"
RF_CLI="$app/Contents/MacOS/ramble-flow"

# ---------------------------------------------------------------------------------------------
# Take over an earlier command-line install (same settings folder; it used Full Disk Access)
# ---------------------------------------------------------------------------------------------
if [[ -f "$old_cli" && "$(signing_id_of "$old_cli")" == "$release_id" ]]; then
  stop_agent
  remove_old_cli
fi

# ---------------------------------------------------------------------------------------------
# Install the app (only when it changed)
# ---------------------------------------------------------------------------------------------
# Built from the same sources with the same Swift means the same app, even when a clean rebuild
# is not byte-identical; then the installed copy is kept untouched.
source_fingerprint="$( { swift --version 2>/dev/null; echo "hooks=$test_hooks"; cat Package.swift VERSION; \
  find Sources Resources scripts/make-app.sh scripts/make-icon.swift LICENSE THIRD_PARTY_NOTICES.md -type f -print0 \
  | LC_ALL=C sort -z | xargs -0 shasum -a 256; } | shasum -a 256 | cut -d' ' -f1)"
build_record="$RF_SUPPORT/installed-app"
app_hash() { cat "$1/Contents/MacOS/RambleFlow" "$1/Contents/MacOS/ramble-flow" "$1/Contents/Info.plist" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }
installed_matches() {
  is_ours "$app" || return 1
  [[ "$(app_hash "$staged")" == "$(app_hash "$app")" ]] && return 0
  [[ -f "$build_record" ]] || return 1
  [[ "$(sed -n 's/^source=//p' "$build_record")" == "$source_fingerprint" && "$(sed -n 's/^app=//p' "$build_record")" == "$(app_hash "$app")" ]]
}
record_build() {
  mkdir -p "$RF_SUPPORT" && chmod 700 "$RF_SUPPORT"
  printf 'source=%s\napp=%s\n' "$source_fingerprint" "$(app_hash "$app")" > "$build_record"
}

changed_flag=()
if installed_matches; then
  say "  App unchanged: $(tilde "$app")"
  record_build
else
  if is_ours "$app"; then
    say "  This checkout builds a new version of the app. Stopping the background app to replace it."
    stop_agent
    changed_flag=(--binary-changed)
  fi
  mkdir -p "$app_dir"
  incoming="$app_dir/.Ramble Flow.installing.app"
  if [[ -e "$incoming" ]]; then rm -r "$incoming"; fi
  ditto "$staged" "$incoming"
  codesign --verify --strict "$incoming" >/dev/null 2>&1 || fail "the app's signature did not verify."
  if is_ours "$app"; then rm -r "$app"; fi
  mv "$incoming" "$app"
  "$lsregister" -f "$app" >/dev/null 2>&1 || true
  "$lsregister" -u "$staged" >/dev/null 2>&1 || true
  record_build
  say "  Installed $(tilde "$app")"
fi

# The questions, the folder dialogs and starting the background app happen in the program.
exec "$RF_CLI" setup ${changed_flag[@]+"${changed_flag[@]}"} ${setup_args[@]+"${setup_args[@]}"}
