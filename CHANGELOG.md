# Changelog

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
