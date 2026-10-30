# Privacy

Ramble Flow has no servers, accounts, analytics or telemetry.

## What leaves your Mac

- **Audio** of recordings made after setup, to the provider you chose (Groq or OpenAI), over
  HTTPS, with your API key. Uploads are named `audio.m4a`; titles, file names, paths, dates and
  your Apple Account are not sent. The provider's terms and retention apply.
- **Your API key**, in the `Authorization` header of those requests and of the installer's key
  check (`GET /models`, which sends nothing else).
- Nothing else. The provider is never switched automatically.

## What stays on your Mac

| Where | What |
| --- | --- |
| Your transcripts folder | One `.txt` per recording: title, recording time with offset, duration, provider/model, a short ID, the transcript. No location, email or source path. |
| `~/Library/Application Support/Ramble Flow CLI/secrets.env` | Your API key(s), **plaintext**, mode 0600 (readable by your user account and root). |
| `~/Library/Application Support/Ramble Flow CLI/` | `config.json` (settings, folder paths), `grants.json` (the two folder grants: paths and macOS bookmark data), `jobs.sqlite` (job state, titles, and the text of finished transcripts for 7 days), `Work/` (temporary audio, deleted after export), `status.json`. Folder mode 0700. |
| `~/Library/Logs/Ramble Flow CLI/` | `ramble-flow.log` (rotated at 512 KB, three files), `stdout.log`, `stderr.log`. |

Voice Memos may name recordings after a place when its location-based naming is on; Ramble Flow
uses the title Voice Memos shows, so such a title appears in the file name and header.

If your transcripts folder is in Google Drive (or another synced folder), that app uploads the
files under its own settings. Tools with access to that folder can read them; Ramble Flow does
not control or promise that.

## Logs

Logs contain versions, states, a short per-recording reference (a hash, not the title), HTTP
status classes and timings. No titles, transcript text, keys or emails. Every line passes a
redactor that removes key-shaped strings. Still, look before you share a log.

## Folder access

The background app runs in the App Sandbox. It reads only the recordings folder and writes only to
the transcripts folder you granted in the macOS folder dialog, plus its own data folders above.

## Reading Voice Memos

Ramble Flow reads audio files and, read-only, Voice Memos' own library (`CloudRecordings.db`) for
dates, titles and deletion state. When the library has to be copied for a consistent read, the
copy goes to its private `Work/` folder and is deleted straight away. It never writes, renames or
deletes anything in the Voice Memos folder.
