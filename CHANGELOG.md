# Changelog

## 0.2.0 (unreleased)

- The background work now runs in a tiny sandboxed app, `~/Applications/Ramble Flow.app`, with no
  UI (no Dock icon, menu bar item or window). Full Disk Access is gone: after the questions, the
  installer shows the standard macOS folder dialog for the recordings folder and the transcripts
  folder (click Grant Access), stores the grants as security-scoped bookmarks, and verifies them as
  the background app before starting it.
- Canceling the dialog starts nothing and says how to retry. A grant that stops working (for
  example after an upgrade) makes the installer show the dialog again.
- `./install.sh --status`. The command-line tool lives inside the app; an earlier
  `~/.local/bin/ramble-flow` is removed (settings and key kept).
- The app icon is the Ramble logo (not MIT-licensed; see THIRD_PARTY_NOTICES.md).

## 0.1.0 (unreleased)

First terminal-only version.

- `./install.sh`: builds from source with the Command Line Tools, asks six questions with
  defaults (provider, API key, recordings folder, transcripts folder, language, model), checks
  Full Disk Access as the background process, and starts a per-user LaunchAgent.
- Rerun `./install.sh` to change settings; the API key, the new-recordings cutoff and job state are
  kept. `./install.sh --uninstall` removes the program and never touches recordings or transcripts.
- Groq (`whisper-large-v3`, default) and OpenAI (`gpt-transcribe`); keys in a 0600 file.
- New recordings only; long recordings split under the 25 MB upload cap; per-part progress
  survives crashes; one `.txt` file per recording, written atomically, never overwriting.
