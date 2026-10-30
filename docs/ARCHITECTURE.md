# Architecture

One Swift package, no third-party dependencies, no UI frameworks.

| Target | What it holds |
| --- | --- |
| `RambleFlowCore` | Everything testable without a terminal: Voice Memos source adapter and read-only metadata, discovery, eligibility (cutoff + baseline), SQLite job store, AVFoundation audio preparation and chunk planning, Groq/OpenAI providers, retries, export, settings and the key file, the worker. |
| `RambleFlowCLI` | The installer dialog (`setup`), the access probe, LaunchAgent and `launchctl` handling, the background loop (`run`) and the management commands. |
| `ramble-flow` | The executable: a thin entry point. |
| `ramble-flow-mock-provider` | Development only: loopback stand-in for the provider APIs, used by `scripts/e2e.sh`. Never installed. |

## Processes

```
./install.sh ──build (swift build -c release) ──ad-hoc sign──▶ ~/.local/bin/ramble-flow (only if changed)
      └─exec─▶ ramble-flow setup          questions, key file, config.json, access probe, LaunchAgent
                    └─launchd one-shot──▶ ramble-flow probe-access   (runs as the background process would)
launchd (login, crash) ──▶ ramble-flow run    the worker: one scan + due jobs every 10 s
you ──▶ ramble-flow status | list | retry | approve | skip | pause | resume | logs
```

- `run` holds an exclusive `flock` on `worker.lock`; a second copy exits cleanly (launchd does
  not restart a clean exit: `KeepAlive = {SuccessfulExit = false}`). A crash or `kill -9` is
  restarted after 10 s (`ThrottleInterval`).
- Settings are re-read when `config.json` changes, so rerunning the installer usually needs no
  restart. The agent is restarted only when the program or the plist changed, or it was not
  running.
- `SIGTERM` (logout, `launchctl bootout`) stops after the current step; every step is committed.

## Pipeline

```
Recordings folder ──scan every 10 s──▶ RecordingDiscovery
        │                                   │ EligibilityPolicy (cutoff, baseline)
        ▼                                   ▼
  CloudRecordings.db (read-only,    JobStore (SQLite, WAL, synchronous=FULL)
  one read transaction)                     │
                                            ▼
                    TranscriptionWorker (actor; one job and one request at a time)
   preparing: private snapshot → SHA-256 → AVFoundation inspection
   queued:    provider/model/language snapshot → silence-aware chunk plan (persisted)
   transcribing: per chunk: encode (AAC mono 24 kHz 48 kbit/s) → size check → upload → commit text
   readyToExport: source fingerprint re-check → reserved name → exclusive atomic rename
   exported
```

Durable states: `discovered → waitingForSync → preparing → queued → transcribing → readyToExport →
exported`, plus `excluded`, `needsDecision`, `retryScheduled`, `needsCredentials`,
`needsFolderAccess`, `needsAttention`, `providerOutcomeUnknown`, `unsupportedAudio`,
`sourceChanged`, `canceled`.

### Eligibility ("new recordings only")

When the background process can first list the recordings folder after setup, it stores a cutoff
instant and the set of files present (the baseline). A recording is eligible only if its
*recording date* is at or after the cutoff:

1. Voice Memos library date (absolute) when available.
2. Otherwise the file name's wall-clock time. Its time zone is unknown, so it decides only when it
   is more than 14 hours after or 12 hours before the cutoff; in between the recording waits for
   you (`needsDecision`: `ramble-flow approve|skip <id>`).
3. A modification time before the cutoff proves a recording is old; it never proves it is new.

The cutoff is set once and never moved by restarts, upgrades, reruns of the installer or
permission repair. If you point the installer at another recordings folder, the files already in
it join the baseline.

### Identity, generations and duplicates

- A recording is identified by its file stem. Voice Memos does not rename files when you rename
  a recording, so a title change never creates a new job.
- Each content version is a generation, fingerprinted by SHA-256 of the private snapshot. A
  change before export drops the old generation's parts; text from two audio versions is never
  joined. After export, edits are not re-transcribed (v1).
- A file with the same content as an existing job is not sent again.

### Chunking

Provider adapters declare an upload cap, a target with headroom and a maximum duration (both
providers: 25 MB cap, 20 MB target; Groq 30 min, OpenAI 20 min). The planner cuts at the quietest
point within the 45 s before each limit (energy profile at 100 ms, streamed). No overlap, so no
text de-duplication. Each encoded part's real size is checked; an oversized part or a 413 splits
that part in two. Silent parts are not uploaded; an all-silent recording produces
`[No speech detected]`. Short AAC recordings under the target are remuxed without re-encoding.

### Failure handling

| Failure | Behavior |
| --- | --- |
| Offline | retry with backoff up to 5 min ("waiting for the internet") |
| 5xx | backoff with jitter, up to 30 min |
| 429 | waits `Retry-After` / `x-ratelimit-reset-*`, else backoff |
| Quota/billing | needs attention; re-checked hourly, no hot loop |
| 401/403 | needs a key; the rejected key's fingerprint is remembered until it changes |
| 413 | split the part, lower that recording's byte cap |
| Model/parameter rejected | needs attention (configuration); no fallback provider |
| Unreadable audio | `unsupportedAudio`, source untouched, `ramble-flow retry` |
| Timeout after sending | counted as uncertain; after 3, `providerOutcomeUnknown` (the provider may have billed) |
| Export failed / folder offline | transcript kept, export retried only; never another folder |
| Key file unreadable | retried in 60 s; not reported as a missing key |

Provider, model and language are snapshotted when a recording's first part is sent. Changes apply
to recordings not started yet; a started recording finishes with its settings.

### Export

Names are reserved per recording, then written via a hidden temp file and
`renamex_np(RENAME_EXCL)` (hard-link fallback), which never replaces an existing file. An
identical existing file means an earlier attempt succeeded. Any other file with that name is left
alone and ` (2)` etc. is used. Titles are NFC-normalized, stripped of path separators, control and
bidi-override characters and bounded to 120 bytes.

## Files

| Path | Contents |
| --- | --- |
| `~/.local/bin/ramble-flow` | the program (`RAMBLE_FLOW_BIN_DIR` to change) |
| `~/Library/LaunchAgents/io.github.tomer-van-cohen.ramble-flow-cli.plist` | the LaunchAgent |
| `~/Library/Application Support/Ramble Flow CLI/` | `config.json`, `secrets.env`, `jobs.sqlite`, `status.json`, `installed-build`, `Work/` (deleted after export; new snapshots pause above 2 GB) |
| `~/Library/Logs/Ramble Flow CLI/` | `ramble-flow.log` (rotated), `stdout.log`, `stderr.log` |
