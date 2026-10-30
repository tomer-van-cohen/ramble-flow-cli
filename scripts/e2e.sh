#!/bin/bash
# End-to-end test of the installed background process. Nothing here touches your real setup:
#
#   - HOME is a temporary folder, so the program, LaunchAgent plist, settings, key file, logs, the
#     "Voice Memos" folder and the "Google Drive" folder all live there;
#   - the LaunchAgent label is unique and contains ".test" (launchd's namespace is per user);
#   - the program is a test-hooks build that talks only to a loopback mock provider
#     (ramble-flow-mock-provider on 127.0.0.1); no audio goes to Groq, OpenAI or anywhere else;
#   - recordings are synthesized with `say`; no real recording is read.
#
# Covers: first install through a real pseudo-terminal (all defaults, hidden key, Full Disk Access
# loop), old recordings excluded (present at setup and late-arriving), new .m4a and .qta
# recordings → exactly one transcript each, a 62-minute recording split under the 25 MB cap, the
# process killed with -9 mid-upload and restarted by launchd without re-sending finished parts,
# rerunning the installer to change settings (live, no restart, cutoff kept), a clean rebuild
# keeping the installed program, and uninstall (keeps recordings and transcripts).
#
#   scripts/e2e.sh            run; everything it created is removed at the end
#   KEEP=1 scripts/e2e.sh     keep the temporary home for inspection (the agent is still removed)
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"

port="${E2E_PORT:-$(( 20000 + RANDOM % 20000 ))}"
label="io.github.tomer-van-cohen.ramble-flow-cli.test-e2e-$$"
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
export RAMBLE_FLOW_NO_OPEN=1
export RAMBLE_FLOW_TEST_PROVIDER_PORT="$port"
export RAMBLE_FLOW_TEST_SCAN_INTERVAL=2
export RAMBLE_FLOW_TEST_STABILITY_WINDOW=3
unset GROQ_API_KEY OPENAI_API_KEY

binary="$home/.local/bin/ramble-flow"
support="$home/Library/Application Support/Ramble Flow CLI"
logs="$home/Library/Logs/Ramble Flow CLI"
plist="$home/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
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
agent_pid() { launchctl print "$domain/$label" 2>/dev/null | sed -nE 's/^[[:space:]]*pid = ([0-9]+)/\1/p' | head -1; }
calls() { [[ -f "$out/mock.log" ]] && wc -l < "$out/mock.log" | tr -d ' ' || echo 0; }
count_txt() { find "$1" -maxdepth 1 -name '*.txt' 2>/dev/null | wc -l | tr -d ' '; }
cutoff() { "$binary" status --json 2>/dev/null | plutil -extract cutoff raw -o - - 2>/dev/null || true; }
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
  chmod -R u+rwX "$work" 2>/dev/null || true
  if [[ "${KEEP:-0}" == 1 ]]; then echo "kept: $work"; else rm -rf "$work"; fi
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

step "Build the mock provider and synthesize audio (say)"
(cd "$repo" && HOME="$work/swiftpm-home" swift build -c release --product ramble-flow-mock-provider >/dev/null)
mock="$(cd "$repo" && HOME="$work/swiftpm-home" swift build -c release --show-bin-path)/ramble-flow-mock-provider"
say -o "$out/clips/en.m4a" --file-format=m4af --data-format=aac "This is a synthetic test recording for Ramble Flow. Nothing here is real."
say -o "$out/clips/en2.m4a" --file-format=m4af --data-format=aac "A second synthetic note, recorded after the settings changed."
say -o "$out/clips/en3.m4a" --file-format=m4af --data-format=aac "A third synthetic note. It only exists to test the new recordings rule."
say -v Carmit -o "$out/clips/he.m4a" --file-format=m4af --data-format=aac "זוהי הקלטת בדיקה סינתטית. אין כאן שום מידע אמיתי." 2>/dev/null \
  || say -o "$out/clips/he.m4a" --file-format=m4af --data-format=aac "Hebrew voice not installed; English stand-in."
swift scripts/e2e/make-audio.swift qta "$out/clips/he.m4a" "$out/clips/he.qta" 2>>"$out/make-audio.stderr"
swift scripts/e2e/make-audio.swift loop "$out/clips/en.m4a" 62 "$out/clips/long.m4a" 2>>"$out/make-audio.stderr"
ls -la "$out/clips"

step "A synthetic Voice Memos library with two old recordings (2 days and 1 hour old)"
sqlite3 "$recordings/CloudRecordings.db" "CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZPATH TEXT, ZUNIQUEID TEXT, ZDATE REAL, ZDURATION REAL, ZENCRYPTEDTITLE TEXT, ZCUSTOMLABEL TEXT, ZEVICTIONDATE REAL); PRAGMA journal_mode=WAL;" >/dev/null
old1=$(add_recording "$out/clips/en.m4a" m4a "Archive one" $(( $(coredata_now) - 172800 )))
old2=$(add_recording "$out/clips/he.qta" qta "Archive two" $(( $(coredata_now) - 3600 )))
touch -t "$(date -v-2d '+%Y%m%d%H%M')" "$recordings/$old1"
touch -t "$(date -v-1H '+%Y%m%d%H%M')" "$recordings/$old2"
# Without Full Disk Access macOS refuses to list this folder; simulate that until the
# installer's permission step.
chmod 000 "$recordings"
start_mock

step "First install in a real terminal: Enter for every default, key typed hidden, access granted midway"
check "expect is available" 'command -v expect >/dev/null'
expect scripts/e2e/first-install.exp "$repo" "$key" "$recordings" "$out/first-install.txt" > /dev/null
check "installer finished" 'grep -q "Done. Transcripts" "$out/first-install.txt"'
check "hidden key never echoed" '! grep -q "$key" "$out/first-install.txt"'
check "masked key shown" 'grep -q "gsk_…wxyz" "$out/first-install.txt"'
check "denied access was detected and explained" 'grep -q "not permitted (macOS privacy protection)" "$out/first-install.txt"'
check "System Settings and Finder were pointed at" 'grep -q "Privacy_AllFiles" "$out/first-install.txt" && grep -q "open -R $binary" "$out/first-install.txt"'
check "access verified after the grant" 'grep -q "Recordings folder    ok (2 recordings there now" "$out/first-install.txt"'
check "Google Drive proposed as the default" 'grep -q "Google Drive for desktop found" "$out/first-install.txt"'
check "LaunchAgent plist in ~/Library/LaunchAgents" '[[ -f "$plist" ]]'
check "agent running under launchd" '[[ -n "$(agent_pid)" ]]'
check "key file is mode 600 in a 700 folder" '[[ "$(stat -f %Lp "$support/secrets.env")" == 600 && "$(stat -f %Lp "$support")" == 700 ]]'
check "key file holds the key; settings do not" 'grep -q "GROQ_API_KEY=$key" "$support/secrets.env" && ! grep -q gsk_ "$support/config.json"'
check "transcripts folder created in My Drive" '[[ -d "$drive/Ramble Flow" ]]'
wait_for "activation" '[[ -n "$(cutoff)" ]]' 30
first_cutoff="$(cutoff)"
echo "cutoff: $first_cutoff"
check "key was checked once (models endpoint), no audio sent" '[[ "$(calls)" == 0 ]]'

step "A late-arriving OLD recording (recorded 3 days ago, synced now)"
late=$(add_recording "$out/clips/en3.m4a" m4a "Late archive" $(( $(coredata_now) - 259200 )))
sleep 2

step "A new .m4a recording"
new1=$(add_recording "$out/clips/en.m4a" m4a "Demo: weekly plan" "$(coredata_now)")
wait_for "first transcript" '[[ "$(count_txt "$drive/Ramble Flow")" == 1 ]]' 120
sleep 6
check "one transcript for one new recording" '[[ "$(count_txt "$drive/Ramble Flow")" == 1 ]]'
check "exactly one provider request (archive and late old recording never uploaded)" '[[ "$(calls)" == 1 ]]'

step "A new .qta (QuickTime) recording with a Hebrew title"
new2=$(add_recording "$out/clips/he.qta" qta "הקלטת בדיקה" "$(coredata_now)")
wait_for "second transcript" '[[ "$(count_txt "$drive/Ramble Flow")" == 2 ]]' 120
check "qta recording transcribed, Hebrew title kept" 'ls "$drive/Ramble Flow" | grep -q "הקלטת בדיקה"'

step "A 62-minute recording; the process is killed (-9) while part 2 is uploading"
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
wait_for "launchd restarts the process" '[[ -n "$(agent_pid)" && "$(agent_pid)" != "$killed" ]]' 60
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
check "program unchanged, so permissions stay valid" 'grep -q "Program unchanged" "$out/rerun.txt"'
check "no restart: same pid" '[[ "$(agent_pid)" == "$pid_before" ]]'
check "cutoff unchanged" '[[ "$(cutoff)" == "$first_cutoff" ]]'
check "key kept" 'grep -q "GROQ_API_KEY=$key" "$support/secrets.env"'
before="$(calls)"
new3=$(add_recording "$out/clips/en2.m4a" m4a "After the change" "$(coredata_now)")
wait_for "transcript in the new folder" '[[ "$(count_txt "$home/Documents/Ramble Flow")" == 1 ]]' 120
check "new transcript went to the new folder; old ones stay in Drive" '[[ "$(count_txt "$drive/Ramble Flow")" == 3 ]]'
check "the language hint was sent" 'tail -1 "$out/mock.log" | grep -q "\"language\":\"he\""'
printf '\n\n\n\n\n\n\n' | ./install.sh > "$out/rerun2.txt" 2>&1
check "next rerun offers the changed values" 'grep -q "Language \[he\]" "$out/rerun2.txt" && grep -q "Folder \[~/Documents/Ramble Flow\]" "$out/rerun2.txt"'

step "A clean rebuild (different bytes) keeps the installed program and its permissions"
rm -rf .build/test-hooks
printf '\n\n\n\n\n\n\n' | ./install.sh > "$out/rerun3.txt" 2>&1
check "clean rebuild: program kept" 'grep -q "Program unchanged" "$out/rerun3.txt"'

step "Status and logs"
"$binary" status | tee "$out/status.txt"
check "status shows running and the cutoff" 'grep -q "running (pid" "$out/status.txt" && grep -q "New recordings since" "$out/status.txt"'
"$binary" list --all > "$out/list.txt"
check "list shows excluded archive and exported recordings" 'grep -q "excluded" "$out/list.txt" && grep -q "exported" "$out/list.txt"'
check "log has no key, no transcript text, no titles" \
  '! grep -rq -e "$key" -e "synthetic transcript" -e "Demo: weekly" -e "Long planning" -e "הקלטת" "$logs"'
check "stderr log is empty (no crashes)" '[[ ! -s "$logs/stderr.log" ]]'

step "Uninstall, keeping settings (answers: Enter = yes, Enter = keep data)"
transcripts_before=$(( $(count_txt "$drive/Ramble Flow") + $(count_txt "$home/Documents/Ramble Flow") ))
recordings_before="$(ls "$recordings" | wc -l | tr -d ' ')"
printf '\n\n' | ./install.sh --uninstall > "$out/uninstall.txt" 2>&1
check "agent unloaded" '! launchctl print "$domain/$label" >/dev/null 2>&1'
check "plist, program and key file removed" '[[ ! -e "$plist" && ! -e "$binary" && ! -e "$support/secrets.env" ]]'
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
