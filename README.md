# Ramble Flow (terminal edition)

Record on your iPhone. Find the transcript in your folder.

Ramble Flow turns new Apple Voice Memos recordings into text files, automatically. When a new
recording reaches your Mac through iCloud, a small background app sends the audio straight to the
transcription provider you chose (Groq or OpenAI), with your own API key, and saves one readable
`.txt` file in a folder you pick: your Google Drive's My Drive if you use Google Drive for desktop,
otherwise Documents.

This edition is for developers. You set it up entirely in the terminal with one script. Enter
accepts every default. Then you click **Grant Access** in one or two standard macOS folder dialogs,
and from then on it runs in the background and starts at login. It has no windows, no Dock icon and
no menu bar item.

> **Status: v0.2, source install only.** Built locally with Apple's free Command Line Tools.

## Quick start

```sh
git clone <repository URL>
cd ramble-flow-cli
./install.sh
```

The script builds a small app (`~/Applications/Ramble Flow.app`) and asks six questions. It then
shows the macOS folder dialog for your recordings folder and for your transcripts folder, already
showing the right place: click **Grant Access** in each. It checks that the background app can
really use both folders, then starts it. A first build takes a minute or two.

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
like this (recorded by `scripts/e2e.sh` in a test home folder, where the clicks in the two folder
dialogs are made by the test's grant helper; you click **Grant Access** twice):

```text
$ ./install.sh
Ramble Flow — install
  Building with Swift 6.3 (the first build takes a minute or two)…
  Installed ~/Applications/Ramble Flow.app

Ramble Flow 0.2.0 — setup
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
     Found.
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

Folder access
  Checking what Ramble Flow can access in the background…
    Recordings folder    not granted yet
    Transcripts folder   not granted yet

  Ramble Flow now shows two standard macOS folder dialogs, one after the other, each already
  showing the right folder. In each, click Grant Access.
    1. ~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings  (read only)
    2. ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive  (a "Ramble Flow" folder is created inside)
  Waiting for the dialog…
    Recordings folder    granted
    Transcripts folder   granted (created ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow)
  Checking again as the background app…
    Recordings folder    ok (2 recordings there now; none of them will be uploaded)
    Transcripts folder   ok

Background process
  Wrote ~/Library/LaunchAgents/io.github.tomer-van-cohen.ramble-flow-cli.plist (starts at login, restarts after a crash).
  Running (pid 4242).
  macOS may show a "Background Items Added" notification: that is this process. If you
  switch it off in System Settings › General › Login Items, Ramble Flow stops.
  Watching for recordings made after 2026-10-30 21:24:59 +02:00. Older ones are never uploaded.

Done. Transcripts of new recordings will appear in ~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/Ramble Flow.
  Status            ./install.sh --status
  Log               ~/Library/Logs/Ramble Flow CLI/ramble-flow.log
  Change settings   ./install.sh
  Uninstall         ./install.sh --uninstall
```

| # | Question | Default | Notes |
| --- | --- | --- | --- |
| 1 | Transcription provider | Groq | `1` Groq (`whisper-large-v3`), `2` OpenAI (`gpt-transcribe`). Audio is sent only to this provider; it is never switched automatically. |
| 2 | API key | the saved key (shown masked), or `$GROQ_API_KEY` / `$OPENAI_API_KEY` if set; none on a first install | Typing is hidden. A new key is checked by listing the provider's models (no audio sent). Stored in a private file, see [Privacy](#privacy). |
| 3 | Voice Memos recordings folder | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings` | Detected automatically. Never written to. |
| 4 | Save transcripts to | `…/GoogleDrive-<account>/My Drive/Ramble Flow` if Google Drive for desktop is set up, else `~/Documents/Ramble Flow` | Created if needed. One `.txt` per recording; existing files are never overwritten. |
| 5 | Spoken language | `auto` | Or an ISO 639-1 hint such as `en` or `he`. Speech is never translated. |
| 6 | Model | the provider's default | Groq also offers `whisper-large-v3-turbo`. Any id is accepted; one the provider rejects is reported, never swapped silently. |

Then a summary and `Apply these settings? [Y/n]`.

## Folder access: what you click

macOS protects the Voice Memos folder, and the background app runs in the App Sandbox. So it
can use only folders you hand it in the standard macOS folder dialog. After the questions, the
installer opens that dialog for you, at most twice, one after the other:

1. **Voice Memos recordings**: the dialog already shows the `Recordings` folder. Click **Grant
   Access**. It is only ever read.
2. **Transcripts**: the dialog shows your transcripts folder, or its parent if the `Ramble Flow`
   folder doesn't exist yet (it is then created inside). Click **Grant Access**.

The app remembers both grants (security-scoped bookmarks), including at login. The installer then
checks, *as the background app*, that it can list the recordings and write a test file in the
transcripts folder before it says "Done". No Full Disk Access, no System Settings, no password, no
`sudo`. When the background item is added, macOS shows a "Background Items Added" notification for
Ramble Flow.

If you cancel a dialog, nothing is started and nothing is uploaded; your answers and key are kept.
Run `./install.sh` again to see the dialog again. Details:
[docs/PERMISSIONS.md](docs/PERMISSIONS.md).

## What happens in the background

- **New recordings only.** The first time the background app can read the recordings folder, it
  remembers that moment (the cutoff) and the recordings already there. Those, and anything recorded
  earlier that iCloud delivers later, are never uploaded. Recordings made after it are transcribed
  even if the Mac was asleep, offline or logged out at the time.
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
- **Long recordings** are split at quiet moments into requests under the providers' 25 MB cap and
  joined into one file. Each finished part is saved before the next is sent, so a crash, a
  `kill -9` or a reboot never re-sends finished parts.
- **Failures wait and retry**: offline, rate limits (`Retry-After`), server errors. A rejected key,
  exhausted quota or unsupported audio waits for you (`./install.sh --status`).
- **Start at login**: a per-user LaunchAgent,
  `~/Library/LaunchAgents/io.github.tomer-van-cohen.ramble-flow-cli.plist`, starts the app's
  executable at login and restarts it if it crashes. It checks for new recordings every 10 seconds.
  Opening the app from Finder does nothing visible.

## Everyday commands

```sh
./install.sh --status                     # running? watching? folders granted? queue, last transcript
```

The full tool lives inside the app:

```sh
alias ramble-flow="$HOME/Applications/Ramble Flow.app/Contents/MacOS/ramble-flow"
ramble-flow status       # same as ./install.sh --status
ramble-flow list         # recent recordings and their state (--all includes old ones)
ramble-flow retry <id>   # retry one that needs attention (or --all)
ramble-flow approve <id> | skip <id>   # a recording whose age could not be established
ramble-flow pause | resume
ramble-flow logs
```

## Changing settings

Run `./install.sh` again from your clone. Every question shows the current value as its default,
so you change only what you want. The API key (Enter keeps it), the new-recordings cutoff, the
folder grants and the job history are kept. A folder dialog appears only for a folder you changed.
The running app picks up new settings within seconds, without a restart. Recordings already being
transcribed finish with the old settings; transcripts already saved stay where they are.

If an earlier version left `~/.local/bin/ramble-flow` behind (the Full Disk Access design), the
installer removes it and keeps your settings and key.

## Logs

`~/Library/Logs/Ramble Flow CLI/ramble-flow.log` (rotated at 512 KB, three files), plus
`stdout.log` and `stderr.log` from launchd. Logs contain states, short hashed recording IDs, HTTP
status codes and timings: never titles, transcript text or keys.

## Uninstall

```sh
./install.sh --uninstall     # or ./uninstall.sh
```

It stops the background app and removes it, its LaunchAgent, the API key file and the folder
grants. It then asks whether to delete settings, job history and logs too (default: keep them, so a
reinstall continues with the same cutoff). `--purge` deletes them without asking; `--yes` skips the
questions. macOS keeps the app's sandbox container (`~/Library/Containers/io.github.tomer-van-cohen.ramble-flow-cli`,
temporary files only) and does not let scripts delete it; drag it to the Trash in Finder if you like. Your **Voice Memos and transcripts are never
touched.**

## Privacy

- **Audio** of new recordings goes to the provider you chose, under your key and that provider's
  terms. Titles, file names and paths are not sent (uploads are named `audio.m4a`). Nothing goes
  anywhere else: no servers of ours, no account, no telemetry.
- **Your API key is a plaintext file readable by your user account, protected by file
  permissions**: `~/Library/Application Support/Ramble Flow CLI/secrets.env`, mode 600, in a
  mode 700 folder. Any program running as you can read it. It is never in the repository, the
  transcripts folder, the LaunchAgent, logs or terminal output. The macOS Keychain is deliberately
  not used: after every local rebuild it would ask for your password, and a background app cannot
  answer that. `GROQ_API_KEY` / `OPENAI_API_KEY` in the environment override the file for
  processes started with them.
- The background app is sandboxed: it reads only the recordings folder you granted and writes only
  to the transcripts folder you granted and its own data folders.
- Settings, folder grants, job state (including recording titles and, for 7 days, the text of
  finished transcripts) and temporary audio stay in
  `~/Library/Application Support/Ramble Flow CLI/`.
- If the transcripts folder is in Google Drive, Google Drive syncs it; Ramble Flow does not talk to
  Google.

More: [docs/PRIVACY.md](docs/PRIVACY.md), [SECURITY.md](SECURITY.md).

## Limitations

- Voice Memos' storage is an internal Apple layout, not a public API; a macOS update may move it.
  Rerun `./install.sh` to point at the new place.
- Recording dates come from Voice Memos' own library when it can be read; otherwise from the file
  name. When that date is too close to the cutoff to tell (the iPhone's time zone is unknown), the
  recording waits for `ramble-flow approve` or `skip` instead of uploading.
- If a folder grant ever stops working (for example after an upgrade), Ramble Flow waits and
  `./install.sh` shows the dialog again.
- If the granted transcripts folder is deleted or its drive goes away, results wait; Ramble Flow
  cannot recreate a folder it has no grant for and never writes elsewhere. Rerun `./install.sh`.
- No re-transcription of recordings edited after their transcript was saved; no import of older
  recordings; no speaker names or summaries.
- It sees recordings synced from all your devices, not only the iPhone.
- Transcription quality, limits and prices are the provider's. Free tiers have rate limits;
  Ramble Flow waits and retries.

Troubleshooting: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## For developers

```sh
./scripts/test.sh        # unit and integration tests (synthetic audio, mock HTTP)
./scripts/e2e.sh         # installer + launchd background app end to end, in a temporary HOME,
                         # with a loopback mock provider (no audio leaves the Mac)
./scripts/check-repo.sh  # no keys, home paths, audio or runtime output tracked
```

[Architecture](docs/ARCHITECTURE.md) · [Permissions](docs/PERMISSIONS.md) ·
[Providers](docs/PROVIDERS.md) · [Manual tests](docs/MANUAL-TESTS.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

## License

Source code: MIT (see [LICENSE](LICENSE); copyright holder to be confirmed before public release).
The Ramble logo used as the app icon and the "Ramble" / "Ramble Flow" names are **not** covered by
the MIT license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
