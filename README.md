# Ramble Flow (command line)

Record on your iPhone. Find the transcript in your folder.

Ramble Flow turns new Apple Voice Memos recordings into text files, automatically. When a new
recording reaches your Mac through iCloud, a small background process sends the audio straight to
the transcription provider you chose (Groq or OpenAI), with your own API key, and saves one
readable `.txt` file in a folder you pick: your Google Drive's My Drive if you use Google Drive for
desktop, otherwise Documents.

This version is for developers: no app, no windows, no menu bar or Dock icon. You install it from
a clone with one script, answer a few questions (Enter accepts every default), and it runs in the
background from then on, starting at login.

> **Status: v0.1, source install only.** Built locally with Apple's free Command Line Tools.

## Quick start

```sh
git clone <repository URL>
cd ramble-flow-cli
./install.sh
```

The script builds the program, asks six questions, helps you grant one macOS permission, checks
that it really works, and starts the background process. A first build takes a minute or two.

## Prerequisites

- A Mac with **Apple silicon** and **macOS 14 or later** (tested on macOS 26.7; other versions and
  Intel Macs are untested).
- Apple's **Command Line Tools** with Swift 5.10 or later. If you don't have them, run
  `xcode-select --install`, finish Apple's installer, then run `./install.sh` again. Xcode,
  Homebrew, Node, Python and ffmpeg are **not** needed.
- Voice Memos with **iCloud** turned on, on your iPhone and on this Mac, with the same Apple
  Account, so your recordings appear in Voice Memos on the Mac.
- An API key from [Groq](https://console.groq.com/keys) (has a free tier with rate limits) or
  [OpenAI](https://platform.openai.com/api-keys).

## The questions

Each question shows its default in `[brackets]`; press Enter to accept it. A first install looks
like this (recorded by `scripts/e2e.sh` in a test home folder; the key was typed at the hidden
prompt, and Full Disk Access was switched on before the second check):

```text
$ ./install.sh
Ramble Flow — install
  Building with Swift 6.3 (the first build takes a minute or two)…
  Installed ~/.local/bin/ramble-flow
  Tip: ~/.local/bin is not on your PATH; use the full path, or add it to PATH.

Ramble Flow 0.1.0 — setup
Turns new Voice Memos recordings into text files, in the background.
Press Enter to accept the value in [brackets].

1/6  Transcription provider
     1) Groq    whisper-large-v3; has a free tier with rate limits
     2) OpenAI  gpt-transcribe
     Audio of new recordings is sent only to the provider you choose.
     Provider [1]: 

2/6  Groq API key
     Get one at https://console.groq.com/keys. It is stored in a plaintext file that only
     your user account can read: ~/Library/Application Support/Ramble Flow CLI/secrets.env (mode 600).
     API key (typing is hidden): 
     Received gsk_…wxyz.
     Checking the key with Groq (lists models; no audio is sent)… accepted.

3/6  Voice Memos recordings folder
     Found. macOS protects it; Full Disk Access is set up in a moment.
     Folder [~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings]: 

4/6  Save transcripts to
     Google Drive for desktop found (you@example.com). Files saved here sync to My Drive.
     One .txt file per recording. The folder is created if needed; existing files are never overwritten.
     Folder [~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow]: 

5/6  Spoken language
     auto detects the language of each recording. A hint (ISO 639-1, such as en, he, es)
     can help when all your recordings are in one language. Speech is never translated.
     Language [auto]: 

6/6  Model
     Groq default: whisper-large-v3. Also available: whisper-large-v3-turbo.
     Model [whisper-large-v3]: 

Summary
  Provider      Groq / whisper-large-v3
  API key       gsk_…wxyz (secrets.env, readable only by you)
  Recordings    ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings
  Transcripts   ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow
  Language      auto
  Apply these settings? [Y/n]: 
  Saved ~/Library/Application Support/Ramble Flow CLI/config.json.

Permissions
  Checking what the background process (~/.local/bin/ramble-flow) can access…
    Recordings folder    not permitted (macOS privacy protection)
    Transcripts folder   ok (created ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow)

  macOS lets a program read the Voice Memos folder only with Full Disk Access. Grant it to
  exactly one program, the background process. It only reads the recordings folder you chose
  and writes only to your transcripts folder. No other permission is needed.
  1. Opening System Settings › Privacy & Security › Full Disk Access.
  2. Showing ramble-flow in Finder. Drag it into the list, or click +, press ⌘⇧G, paste
     /Users/you/.local/bin/ramble-flow
     and click Open. macOS asks for your password.
  3. Make sure the switch next to ramble-flow is on.
  Press Enter to check again, or s to skip for now: 
  Checking again…
    Recordings folder    ok (2 recordings there now; none of them will be uploaded)
    Transcripts folder   ok

Background process
  Wrote ~/Library/LaunchAgents/io.github.tomer-van-cohen.ramble-flow-cli.plist (starts at login, restarts after a crash).
  Running (pid 4242).
  macOS may show a "Background Items Added" notification: that is this process. If you
  switch it off in System Settings › General › Login Items, Ramble Flow stops.
  Watching for recordings made after 2026-10-30 20:29:47 +02:00. Older ones are never uploaded.

Done. Transcripts of new recordings will appear in ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow.
  Status            ~/.local/bin/ramble-flow status
  Log               ~/Library/Logs/Ramble Flow CLI/ramble-flow.log
  Change settings   ./install.sh
  Uninstall         ./install.sh --uninstall
```

| # | Question | Default | Notes |
| --- | --- | --- | --- |
| 1 | Transcription provider | Groq | `1` Groq (`whisper-large-v3`), `2` OpenAI (`gpt-transcribe`). Audio is sent only to this provider; it is never switched automatically. |
| 2 | API key | the saved key (shown masked), or `$GROQ_API_KEY` / `$OPENAI_API_KEY` if set; none on a first install | Typing is hidden. A new key is checked by listing the provider's models (no audio sent). Stored in a private file, see [Privacy](#privacy). |
| 3 | Voice Memos recordings folder | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings` | Detected automatically. Another folder is accepted only if it looks like Voice Memos, or after you confirm. Never written to. |
| 4 | Save transcripts to | `…/GoogleDrive-<account>/My Drive/Ramble Flow` if Google Drive for desktop is set up, else `~/Documents/Ramble Flow` | Created if needed. One `.txt` per recording; existing files are never overwritten. |
| 5 | Spoken language | `auto` | Or an ISO 639-1 hint such as `en` or `he`. Speech is never translated. |
| 6 | Model | the provider's default | Groq also offers `whisper-large-v3-turbo`. Any id is accepted; one the provider rejects is reported, never swapped silently. |

Then a summary and `Apply these settings? [Y/n]`.

## Permissions

macOS protects the Voice Memos folder. The background program,
`~/.local/bin/ramble-flow`, needs **Full Disk Access** to read it. That is the only permission.
No microphone, screen recording, Accessibility, Automation or Keychain access, and no `sudo`.

The installer checks access *as the background process* (a one-shot launchd job, because a
Terminal that has Full Disk Access of its own would hide the problem). If access is missing it:

1. opens **System Settings › Privacy & Security › Full Disk Access**;
2. shows `ramble-flow` in Finder: drag it into the list (or click **+**, press ⌘⇧G and paste the
   path it prints), switch it on, enter your password;
3. waits for Enter and checks again, until it works (or `s` to skip for now: the process then waits
   and uploads nothing until access works).

If the transcripts folder is in Google Drive, macOS may also ask once whether `ramble-flow` may
access files in Google Drive: allow it. When the LaunchAgent is added, macOS shows a "Background
Items Added" notification; that is this process.

macOS ties Full Disk Access to the exact program build. Rerunning `./install.sh` from the same
checkout keeps the installed program, so the permission stays. After a `git pull` that changes the
code, the installer tells you to remove the old `ramble-flow` entry (−) and add it again, and
verifies it. Details: [docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## What happens in the background

- **New recordings only.** The first time the background process can read the recordings folder,
  it remembers that moment (the cutoff) and the recordings already there. Those, and anything
  recorded earlier that iCloud delivers later, are never uploaded. Recordings made after it are
  transcribed even if the Mac was asleep, offline or logged out at the time.
- **One file per recording**, in the recording's language:

  ```text
  Title: Meeting notes
  Recorded: 2026-10-30T12:50:48+02:00
  Duration: 00:32:18
  Transcribed with: Groq / whisper-large-v3
  Recording ID: a1b2c3d4

  …transcript…
  ```

  Named `2026-10-30 12-50-48 — Meeting notes — a1b2c3d4.txt`.
- **Long recordings** are split at quiet moments into requests under the providers' 25 MB cap
  and joined into one file. Each finished part is saved before the next is sent, so a crash, a
  `kill -9` or a reboot never re-sends finished parts.
- **Failures wait and retry**: offline, rate limits (`Retry-After`), server errors. A rejected key,
  exhausted quota or unsupported audio waits for you (`ramble-flow status`, `ramble-flow list`).
- **Start at login**: a per-user LaunchAgent,
  `~/Library/LaunchAgents/io.github.tomer-van-cohen.ramble-flow-cli.plist`, starts
  `ramble-flow run` at login and restarts it if it crashes. It checks for new recordings every 10
  seconds.

## Everyday commands

```sh
~/.local/bin/ramble-flow status     # running? watching? queue, last transcript
~/.local/bin/ramble-flow list       # recent recordings and their state (--all includes old ones)
~/.local/bin/ramble-flow retry <id> # retry one that needs attention (or --all)
~/.local/bin/ramble-flow approve <id> | skip <id>   # a recording whose age could not be established
~/.local/bin/ramble-flow pause | resume
~/.local/bin/ramble-flow logs
```

Add `~/.local/bin` to your `PATH` to type just `ramble-flow`.

## Changing settings

Run `./install.sh` again from your clone. Every question shows the current value as its default,
so you change only what you want. The API key (Enter keeps it), the new-recordings cutoff and the
job history are kept. The running process picks up new settings within seconds, without a
restart. Recordings already being transcribed finish with the old settings; transcripts already
saved stay where they are.

## Logs

`~/Library/Logs/Ramble Flow CLI/ramble-flow.log` (rotated at 512 KB, three files), plus
`stdout.log` and `stderr.log` from launchd. Logs contain states, short hashed recording IDs,
HTTP status codes and timings: never titles, transcript text or keys.

## Uninstall

```sh
./install.sh --uninstall     # or ./uninstall.sh
```

It stops and unloads the background process and removes the LaunchAgent, the program and the API
key file. It then asks whether to delete settings, job history and logs too (default: keep them,
so a reinstall continues with the same cutoff). `--purge` deletes them without asking, `--yes`
skips the questions. Your **Voice Memos and transcripts are never touched.** One manual step: remove
`ramble-flow` from System Settings › Privacy & Security › Full Disk Access with −.

## Privacy

- **Audio** of new recordings goes to the provider you chose, under your key and that provider's
  terms. Titles, file names and paths are not sent (uploads are named `audio.m4a`). Nothing goes
  anywhere else: no servers of ours, no account, no telemetry.
- **Your API key is a plaintext file readable by your user account, protected by file
  permissions**: `~/Library/Application Support/Ramble Flow CLI/secrets.env`, mode 600, in a mode
  700 folder. Any program running as you can read it. It is never in the repository, the
  transcripts folder, the LaunchAgent, logs or terminal output. The macOS Keychain is deliberately
  not used: it would show password prompts after every rebuild, which a background process cannot
  answer. `GROQ_API_KEY` / `OPENAI_API_KEY` in the environment override the file for processes
  started with them.
- Settings, job state (including recording titles and, for 7 days, the text of finished
  transcripts) and temporary audio stay in `~/Library/Application Support/Ramble Flow CLI/`.
- If the transcripts folder is in Google Drive, Google Drive syncs it; Ramble Flow does not talk to
  Google.

More: [docs/PRIVACY.md](docs/PRIVACY.md), [SECURITY.md](SECURITY.md).

## Limitations

- Voice Memos' storage is an internal Apple layout, not a public API; a macOS update may move it.
  Ramble Flow then reports the folder as not found; rerun `./install.sh` to point at the new place.
- Recording dates come from Voice Memos' own library when it can be read; otherwise from the file
  name. When that date is too close to the cutoff to tell (the iPhone's time zone is unknown), the
  recording waits for `ramble-flow approve` or `skip` instead of uploading.
- Full Disk Access must be granted again after an upgrade that changes the program (see
  Permissions). Until then, the process waits.
- No re-transcription of recordings edited after their transcript was saved; no import of older
  recordings; no speaker names or summaries.
- It sees recordings synced from all your devices, not only the iPhone.
- Transcription quality, limits and prices are the provider's. Free tiers have rate limits;
  Ramble Flow waits and retries.

Troubleshooting: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## For developers

```sh
./scripts/test.sh        # unit and integration tests (synthetic audio, mock HTTP)
./scripts/e2e.sh         # installer + launchd background process end to end, in a temporary HOME,
                         # with a loopback mock provider (no audio leaves the Mac)
./scripts/check-repo.sh  # no keys, home paths, audio or runtime output tracked
```

[Architecture](docs/ARCHITECTURE.md) · [Permissions](docs/PERMISSIONS.md) ·
[Providers](docs/PROVIDERS.md) · [Manual tests](docs/MANUAL-TESTS.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

## License

Source code: MIT (see [LICENSE](LICENSE); copyright holder to be confirmed before public release).
The "Ramble" and "Ramble Flow" names are not covered by the code license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
