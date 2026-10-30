#!/bin/bash
# End-to-end test of the installer and the installed background app. Nothing here touches your
# real setup:
#
#   - HOME is a temporary folder: the app bundle, LaunchAgent plist, settings, key file, folder
#     grants, logs, the "Voice Memos" folder and the "Google Drive" folder all live there;
#   - the app is a test-hooks build with its own bundle id (…ramble-flow-cli.test, so its sandbox
#     container and grants are separate) and a unique ".test" LaunchAgent label;
#   - the provider is a loopback mock (ramble-flow-mock-provider on 127.0.0.1); no audio goes to
#     Groq, OpenAI or anywhere else; recordings are synthesized with `say`.
#
# The one thing a script cannot do is click the macOS folder dialog: for a sandboxed app, macOS
# refuses programmatic answers (by design). The test therefore uses a *grant helper*: the same app
# signed with the same bundle id plus a temporary sandbox exception for the test HOME, which records
# the folder grants (app-scoped bookmarks) without showing the dialog. The installed app has no
# such exception: it reaches the folders only through those bookmarks, from launchd.
#
# Covers: an earlier Full-Disk-Access install taken over (stray program removed, settings and key
# kept); first install through a real pseudo-terminal (hidden key, all defaults) with the dialog
# canceled → nothing started; rerun with Enter only → grants recorded, verified as the background
# app, agent started; old recordings excluded; new .m4a/.qta → one transcript each; a 62-minute
# recording split under 25 MB; kill -9 mid-upload → launchd restarts, finished parts not re-sent;
# rerun to change settings (new transcripts folder → one new grant, no restart); clean rebuild
# keeps the app; status/logs; uninstall (recordings and transcripts untouched).
#
#   scripts/e2e.sh            run; everything it created is removed at the end
#   KEEP=1 scripts/e2e.sh     keep the temporary home for inspection (agents are still removed)
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
real_home="$HOME"

port="${E2E_PORT:-$(( 20000 + RANDOM % 20000 ))}"
label="io.github.tomer-van-cohen.ramble-flow-cli.test-e2e-$$"
test_id="io.github.tomer-van-cohen.ramble-flow-cli.test"
work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ramble-flow-e2e.XXXXXX")" && pwd -P)"
home="$work/home"
out="$work/out"
mkdir -p "$home/Documents" "$out/clips"
recordings="$home/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"
drive="$home/Library/CloudStorage/GoogleDrive-tester@example.com/My Drive"
mkdir -p "$recordings" "$drive"
key="gsk_e2e_synthetic_key_0000000000000000wxyz"

export HOME="$home"
export RAMBLE_FLOW_LABEL="$label"
export RAMBLE_FLOW_TEST_HOOKS=1
export RAMBLE_FLOW_TEST_PROVIDER_PORT="$port"
export RAMBLE_FLOW_TEST_SCAN_INTERVAL=2
export RAMBLE_FLOW_TEST_STABILITY_WINDOW=3
unset GROQ_API_KEY OPENAI_API_KEY

app="$home/Applications/Ramble Flow.app"
cli="$app/Contents/MacOS/ramble-flow"
support="$home/Library/Application Support/Ramble Flow CLI"
logs="$home/Library/Logs/Ramble Flow CLI"
plist="$home/Library/LaunchAgents/$label.plist"
helper="$work/helper/Ramble Flow.app"
domain="gui/$(id -u)"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
failures=0
mock_pid=""

step() { printf '\n== %s\n' "$*"; }
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi; }
wait_for() { # description, condition, seconds
  local deadline=$(( $(date +%s) + $3 ))
  until eval "$2"; do
    if (( $(date +%s) > deadline )); then echo "timeout waiting for: $1"; return 1; fi
    sleep 1
  done
}
agent_pid() { launchctl print "$domain/$label" 2>/dev/null | sed -nE 's/^	pid = ([0-9]+)/\1/p' | head -1; }
calls() { [[ -f "$out/mock.log" ]] && wc -l < "$out/mock.log" | tr -d ' ' || echo 0; }
count_txt() { find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '; }
cutoff() { "$cli" status --json 2>/dev/null | plutil -extract cutoff raw -o - - 2>/dev/null || true; }
coredata_now() { echo $(( $(date +%s) - 978307200 )); }

start_mock() { # extra env assignments
  stop_mock
  env MOCK_PORT="$port" MOCK_LOG="$out/mock.log" "$@" "$mock" 2>>"$out/mock.stderr" &
  mock_pid=$!
  wait_for "mock provider" 'curl -s "http://127.0.0.1:$port/" >/dev/null' 15
}
stop_mock() { if [[ -n "$mock_pid" ]]; then kill "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true; mock_pid=""; fi; }
cleanup() {
  stop_mock
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchctl bootout "$domain/$label.access-probe" >/dev/null 2>&1 || true
  "$lsregister" -u "$app" >/dev/null 2>&1 || true
  "$lsregister" -u "$helper" >/dev/null 2>&1 || true
  "$lsregister" -u "$repo/.build/test-hooks/install-staging/Ramble Flow.app" >/dev/null 2>&1 || true
  # The test app's sandbox container lives in the real home (macOS puts it there whatever HOME is).
  # macOS protects it from deletion by scripts; it holds only temporary files and every run reuses
  # the same one (…ramble-flow-cli.test). Its contents are emptied where permitted.
  if [[ -d "$real_home/Library/Containers/$test_id" ]]; then rm -r "$real_home/Library/Containers/$test_id" 2>/dev/null || true; fi
  chmod -R u+rwX "$work" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept: $work"; else rm -r "$work"; fi
}
trap cleanup EXIT

add_recording() { # source-audio, extension, title, coredata-date
  local name; name="$(date -r $(( $4 + 978307200 )) '+%Y%m%d %H%M%S')-$(uuidgen | cut -c1-8).$2"
  cp "$1" "$recordings/$name"
  local seconds; seconds="$(afinfo "$1" | sed -nE 's/estimated duration: ([0-9.]+).*/\1/p')"
  sqlite3 "$recordings/CloudRecordings.db" \
    "INSERT INTO ZCLOUDRECORDING (ZPATH, ZUNIQUEID, ZDATE, ZDURATION, ZENCRYPTEDTITLE) VALUES ('$name', '$(uuidgen)', $4, ${seconds:-0}, '$3');"
  echo "$name"
}

step "Build the test-hooks program, the mock provider and the grant helper; synthesize audio"
(cd "$repo" && for p in ramble-flow RambleFlow ramble-flow-mock-provider; do
  HOME="$real_home" swift build -c release --product "$p" --build-path .build/test-hooks -Xswiftc -DRAMBLE_FLOW_TEST_HOOKS >/dev/null; done)
bin="$(cd "$repo" && HOME="$real_home" swift build -c release --build-path .build/test-hooks -Xswiftc -DRAMBLE_FLOW_TEST_HOOKS --show-bin-path)"
mock="$bin/ramble-flow-mock-provider"
# Grant helper: same app, same bundle id, plus a sandbox exception for the test HOME only.
mkdir -p "$work/helper"
cp Resources/RambleFlow.entitlements "$work/helper.entitlements"
plutil -insert "com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write" -array "$work/helper.entitlements"
plutil -insert "com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write" -string "$home/" -append "$work/helper.entitlements"
HOME="$real_home" scripts/make-app.sh --bin-dir "$bin" --output "$helper" --entitlements "$work/helper.entitlements" --test-hooks
export RAMBLE_FLOW_TEST_GRANT_APP="$helper"
export RAMBLE_FLOW_TEST_GRANT_MODE=auto
say -o "$out/clips/en.m4a" --file-format=m4af --data-format=aac "This is a synthetic test recording for Ramble Flow. Nothing here is real."
say -o "$out/clips/en2.m4a" --file-format=m4af --data-format=aac "A second synthetic note, recorded after the settings changed."
say -o "$out/clips/en3.m4a" --file-format=m4af --data-format=aac "A third synthetic note. It only exists to test the new recordings rule."
say -v Carmit -o "$out/clips/he.m4a" --file-format=m4af --data-format=aac "זוהי הקלטת בדיקה סינתטית. אין כאן שום מידע אמיתי." 2>/dev/null \
  || say -o "$out/clips/he.m4a" --file-format=m4af --data-format=aac "Hebrew voice not installed; English stand-in."
swift scripts/e2e/make-audio.swift qta "$out/clips/he.m4a" "$out/clips/he.qta" 2>>"$out/make-audio.stderr"
swift scripts/e2e/make-audio.swift loop "$out/clips/en.m4a" 62 "$out/clips/long.m4a" 2>>"$out/make-audio.stderr"

step "A synthetic Voice Memos library with two old recordings (2 days and 1 hour old)"
sqlite3 "$recordings/CloudRecordings.db" "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZPATH TEXT, ZUNIQUEID TEXT, ZDATE REAL, ZDURATION REAL, ZENCRYPTEDTITLE TEXT, ZCUSTOMLABEL TEXT, ZEVICTIONDATE REAL); PRAGMA journal_mode=WAL;" >/dev/null
old1=$(add_recording "$out/clips/en.m4a" m4a "Archive one" $(( $(coredata_now) - 172800 )))
old2=$(add_recording "$out/clips/he.qta" qta "Archive two" $(( $(coredata_now) - 3600 )))
touch -t "$(date -v-2d '+%Y%m%d%H%M')" "$recordings/$old1"
touch -t "$(date -v-1H '+%Y%m%d%H%M')" "$recordings/$old2"
start_mock

step "First install in a real terminal: key typed at the hidden prompt, Enter elsewhere; the folder dialog is canceled"
check "expect is available" 'command -v expect >/dev/null'
RAMBLE_FLOW_TEST_GRANT_MODE=cancel expect scripts/e2e/install.exp "$repo" "$out/install-canceled.txt" "$key" canceled >/dev/null || true
check "hidden key never echoed" '! grep -q "$key" "$out/install-canceled.txt"'
check "masked key shown" 'grep -q "gsk_…wxyz" "$out/install-canceled.txt"'
check "Google Drive proposed as the default" 'grep -q "Google Drive for desktop found" "$out/install-canceled.txt"'
check "access check found nothing granted yet" 'grep -q "Recordings folder    not granted yet" "$out/install-canceled.txt"'
check "cancel explained, with how to retry" 'grep -q "You canceled the folder dialog" "$out/install-canceled.txt" && grep -q "Run ./install.sh again" "$out/install-canceled.txt"'
check "nothing started after cancel" '[[ ! -f "$plist" ]] && ! launchctl print "$domain/$label" >/dev/null 2>&1'
check "key and settings saved for the next run" 'grep -q "GROQ_API_KEY=$key" "$support/secrets.env" && [[ -f "$support/config.json" ]]'
check "no Full Disk Access anywhere" '! grep -qi "full disk" "$out/install-canceled.txt"'

step "Simulate the earlier Full-Disk-Access version's leftovers (a program in ~/.local/bin)"
mkdir -p "$home/.local/bin"
cp "$bin/ramble-flow" "$home/.local/bin/ramble-flow"
codesign --force --sign - --identifier io.github.tomer-van-cohen.ramble-flow-cli "$home/.local/bin/ramble-flow" >/dev/null 2>&1
echo "source=old" > "$support/installed-build"

step "Rerun in a real terminal pressing only Enter: dialogs answered, verified as the background app, started"
expect scripts/e2e/install.exp "$repo" "$out/install.txt" - done >/dev/null
check "installer finished" 'grep -q "Done. Transcripts" "$out/install.txt"'
check "earlier program removed, settings and key kept" '[[ ! -e "$home/.local/bin/ramble-flow" ]] && grep -q "Removed the earlier command-line program" "$out/install.txt" && grep -q "GROQ_API_KEY=$key" "$support/secrets.env"'
check "saved key offered as the default" 'grep -q "\[keep gsk_…wxyz\]" "$out/install.txt"'
check "two folder dialogs announced" 'grep -q "two standard macOS folder dialogs" "$out/install.txt"'
check "both folders granted, transcripts folder created inside My Drive" 'grep -q "Recordings folder    granted" "$out/install.txt" && grep -q "Transcripts folder   granted (created" "$out/install.txt" && [[ -d "$drive/Ramble Flow" ]]'
check "verified as the background app: 2 old recordings visible" 'grep -q "Recordings folder    ok (2 recordings there now" "$out/install.txt"'
check "grants stored as bookmarks (mode 600)" '[[ -f "$support/grants.json" && "$(stat -f %Lp "$support/grants.json")" == 600 ]] && grep -q "\"bookmark\"" "$support/grants.json"'
entitlement_paths() { codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep -oE '"/[^"]*"'; }
check "app bundle installed, LSUIElement, sandboxed, file exceptions only for its own data folders" \
  '[[ -d "$app" ]] && [[ "$(plutil -extract LSUIElement raw "$app/Contents/Info.plist")" == true ]] && codesign -d --entitlements - "$app" 2>/dev/null | grep -q app-sandbox && [[ "$(entitlement_paths | wc -l | tr -d " ")" == 2 ]] && [[ -z "$(entitlement_paths | grep -v "Ramble Flow CLI/\"$")" ]]'
check "the grant helper is a different build than the installed app" '[[ "$(codesign -dvvv "$helper" 2>&1 | grep CDHash=)" != "$(codesign -dvvv "$app" 2>&1 | grep CDHash=)" ]]'
check "LaunchAgent runs the app's executable" 'plutil -extract ProgramArguments.0 raw "$plist" | grep -q "Ramble Flow.app/Contents/MacOS/RambleFlow"'
check "agent running under launchd" '[[ -n "$(agent_pid)" ]]'
check "agent runs in its App Sandbox container" 'ps -o command= -p "$(agent_pid)" | grep -q "RambleFlow run" && [[ -d "$real_home/Library/Containers/$test_id" ]]'
check "key file is mode 600 in a 700 folder" '[[ "$(stat -f %Lp "$support/secrets.env")" == 600 && "$(stat -f %Lp "$support")" == 700 ]]'
check "no Full Disk Access anywhere" '! grep -qi "full disk" "$out/install.txt"'
wait_for "activation" '[[ -n "$(cutoff)" ]]' 30
first_cutoff="$(cutoff)"
echo "cutoff: $first_cutoff"
check "no audio sent so far (key check uses the models endpoint)" '[[ "$(calls)" == 0 ]]'

step "A late-arriving OLD recording (recorded 3 days ago, synced now)"
late=$(add_recording "$out/clips/en3.m4a" m4a "Late archive" $(( $(coredata_now) - 259200 )))
sleep 2

step "A new .m4a recording"
new1=$(add_recording "$out/clips/en.m4a" m4a "Demo: weekly plan" "$(coredata_now)")
wait_for "first transcript" '[[ "$(count_txt "$drive/Ramble Flow")" == 1 ]]' 120
sleep 6
check "one transcript for one new recording (read via the bookmark, from launchd)" '[[ "$(count_txt "$drive/Ramble Flow")" == 1 ]]'
check "exactly one provider request (archive and late old recording never uploaded)" '[[ "$(calls)" == 1 ]]'

step "A new .qta (QuickTime) recording with a Hebrew title"
new2=$(add_recording "$out/clips/he.qta" qta "הקלטת בדיקה" "$(coredata_now)")
wait_for "second transcript" '[[ "$(count_txt "$drive/Ramble Flow")" == 2 ]]' 120
check "qta recording transcribed, Hebrew title kept" 'ls "$drive/Ramble Flow" | grep -q "הקלטת בדיקה"'

step "A 62-minute recording; the app is killed (-9) while part 2 is uploading"
before="$(calls)"
stall=$(( before + 2 ))
start_mock MOCK_STALL_CALL="$stall" MOCK_STALL_SECONDS=120
long=$(add_recording "$out/clips/long.m4a" m4a "Long planning session" "$(coredata_now)")
wait_for "request $stall to start" '[[ "$(calls)" -ge "$stall" ]]' 600
sleep 1
killed="$(agent_pid)"
kill -9 "$killed"
echo "killed pid $killed during request $stall"
start_mock
wait_for "launchd restarts the app" '[[ -n "$(agent_pid)" && "$(agent_pid)" != "$killed" ]]' 60
echo "restarted as pid $(agent_pid)"
wait_for "long transcript" '[[ "$(count_txt "$drive/Ramble Flow")" == 3 ]]' 900
long_requests=$(( $(calls) - before ))
echo "requests for the long recording: $long_requests (3 parts + the interrupted one again)"
check "long recording: 3 parts; only the interrupted part was sent twice" '[[ "$long_requests" == 4 ]]'
long_file="$(find "$drive/Ramble Flow" -name '*Long planning session*')"
check "long transcript holds parts 1, 3 (resent 2) and 4 in order, not the interrupted one" \
  'grep -q "part $((before + 1))," "$long_file" && grep -q "part $((before + 3))," "$long_file" && grep -q "part $((before + 4))," "$long_file" && ! grep -q "part $stall," "$long_file" && [[ $(grep -n "part $((before + 1))," "$long_file" | cut -d: -f1) -lt $(grep -n "part $((before + 4))," "$long_file" | cut -d: -f1) ]]'
long_rows() { awk -v b="$before" 'NR>b' "$out/mock.log"; }
check "every upload under 25 MB, authorized, named audio.m4a, model whisper-large-v3" \
  'long_rows | sed -E "s/^[{]\"authorized\":(true|false),\"bytes\":([0-9]+),.*$/\1 \2/" | awk "{ if (\$1 != \"true\" || \$2 >= 25000000) bad = 1 } END { exit bad }" \
   && [[ "$(long_rows | grep -c "\"filename\":\"audio.m4a\"")" == "$long_requests" && "$(long_rows | grep -c "\"model\":\"whisper-large-v3\"")" == "$long_requests" ]]'
long_rows | sed -E 's/^[{]"authorized":[a-z]+,"bytes":([0-9]+),"call":([0-9]+).*$/  request \2: \1 bytes/'

step "Rerun the installer to change settings (piped answers): language he, transcripts to Documents"
pid_before="$(agent_pid)"
printf '\n\n\n%s\nhe\n\n\n' "~/Documents/Ramble Flow" | ./install.sh > "$out/rerun.txt" 2>&1
check "rerun succeeded" 'grep -q "Done. Transcripts" "$out/rerun.txt"'
check "rerun shows the saved key masked as the default" 'grep -q "\[keep gsk_…wxyz\]" "$out/rerun.txt"'
check "rerun shows current folders as defaults" 'grep -q "Folder \[~/Library/CloudStorage/GoogleDrive-tester@example.com/My Drive/Ramble Flow\]" "$out/rerun.txt"'
check "app unchanged" 'grep -q "App unchanged" "$out/rerun.txt"'
check "only the new transcripts folder needed a dialog" 'grep -q "Ramble Flow now shows a standard macOS folder dialog" "$out/rerun.txt" && ! grep -q "    1. ~/Library/Group Containers" "$out/rerun.txt"'
check "no restart: same pid" '[[ "$(agent_pid)" == "$pid_before" ]]'
check "cutoff unchanged" '[[ "$(cutoff)" == "$first_cutoff" ]]'
check "key kept" 'grep -q "GROQ_API_KEY=$key" "$support/secrets.env"'
new3=$(add_recording "$out/clips/en2.m4a" m4a "After the change" "$(coredata_now)")
wait_for "transcript in the new folder" '[[ "$(count_txt "$home/Documents/Ramble Flow")" == 1 ]]' 120
check "new transcript went to the new folder; old ones stay in Drive" '[[ "$(count_txt "$drive/Ramble Flow")" == 3 ]]'
check "the language hint was sent" 'tail -1 "$out/mock.log" | grep -q "\"language\":\"he\""'
printf '\n\n\n\n\n\n\n' | ./install.sh > "$out/rerun2.txt" 2>&1
check "next rerun offers the changed values, no dialog" 'grep -q "Language \[he\]" "$out/rerun2.txt" && grep -q "Folder \[~/Documents/Ramble Flow\]" "$out/rerun2.txt" && ! grep -q "folder dialog" "$out/rerun2.txt"'

step "A clean rebuild (different bytes) keeps the installed app"
rm -r .build/test-hooks/release .build/test-hooks/arm64-apple-macosx
printf '\n\n\n\n\n\n\n' | ./install.sh > "$out/rerun3.txt" 2>&1
check "clean rebuild: app kept" 'grep -q "App unchanged" "$out/rerun3.txt"'

step "Status and logs"
./install.sh --status | tee "$out/status.txt"
check "status shows running, granted folders and the cutoff" 'grep -q "running (pid" "$out/status.txt" && grep -q "(granted)" "$out/status.txt" && grep -q "New recordings since" "$out/status.txt"'
"$cli" list --all > "$out/list.txt"
check "list shows excluded archive and exported recordings" 'grep -q "excluded" "$out/list.txt" && grep -q "exported" "$out/list.txt"'
check "log has no key, no transcript text, no titles" \
  '! grep -rq -e "$key" -e "synthetic transcript" -e "Demo: weekly" -e "Long planning" -e "הקלטת" "$logs"'
check "stderr log is empty (no crashes)" '[[ ! -s "$logs/stderr.log" ]]'

step "Uninstall, keeping settings (answers: Enter = yes, Enter = keep data)"
transcripts_before=$(( $(count_txt "$drive/Ramble Flow") + $(count_txt "$home/Documents/Ramble Flow") ))
recordings_before="$(ls "$recordings" | wc -l | tr -d ' ')"
printf '\n\n' | ./install.sh --uninstall > "$out/uninstall.txt" 2>&1
check "agent unloaded" '! launchctl print "$domain/$label" >/dev/null 2>&1'
check "plist, app, key file and grants removed" '[[ ! -e "$plist" && ! -e "$app" && ! -e "$support/secrets.env" && ! -e "$support/grants.json" ]]'
check "settings and job history kept" '[[ -f "$support/config.json" && -f "$support/jobs.sqlite" ]]'
check "recordings untouched" '[[ "$(ls "$recordings" | wc -l | tr -d " ")" == "$recordings_before" ]]'
check "transcripts untouched" '[[ $(( $(count_txt "$drive/Ramble Flow") + $(count_txt "$home/Documents/Ramble Flow") )) == "$transcripts_before" ]]'
./install.sh --uninstall --yes --purge > "$out/purge.txt" 2>&1
check "purge removes settings and logs" '[[ ! -e "$support" && ! -e "$logs" ]]'
check "purge still leaves recordings and transcripts" '[[ "$(ls "$recordings" | wc -l | tr -d " ")" == "$recordings_before" && $(( $(count_txt "$drive/Ramble Flow") + $(count_txt "$home/Documents/Ramble Flow") )) == "$transcripts_before" ]]'

step "Results"
for f in "$drive/Ramble Flow/"*.txt "$home/Documents/Ramble Flow/"*.txt; do echo "--- $(basename "$f")"; head -7 "$f"; done
mkdir -p "${E2E_ARTIFACTS:-$repo/.build/e2e-artifacts}"
cp "$out/"*.txt "${E2E_ARTIFACTS:-$repo/.build/e2e-artifacts}/" 2>/dev/null || true
echo
if (( failures == 0 )); then echo "End-to-end test passed."; else echo "End-to-end test: $failures failing check(s)."; exit 1; fi
