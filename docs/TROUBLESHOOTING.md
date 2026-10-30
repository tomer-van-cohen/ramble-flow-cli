# Troubleshooting

Start with `./install.sh --status`. The tool inside the app,
`~/Applications/Ramble Flow.app/Contents/MacOS/ramble-flow`, also has `list` (recordings that need
you) and `logs` (the end of the log).

| Status says | What to do |
| --- | --- |
| watching | All good. Nothing to transcribe yet is normal. |
| cannot read the recordings folder | Run `./install.sh` again (Enter through the questions); it shows the folder dialog again and verifies. |
| recordings folder not found | Turn on iCloud for Voice Memos on the iPhone and this Mac (same Apple Account) and open Voice Memos on the Mac once. |
| starting (waiting to read the recordings folder) | The cutoff is set the first time the folder can be read. Same fix as above. |
| transcripts folder unavailable | Google Drive quit or signed out, a disk unplugged, or the folder was removed. Results wait and are saved when it is back; never elsewhere. If the folder was deleted, rerun `./install.sh` to create and grant it again. |
| cannot write to the transcripts folder | Rerun `./install.sh`; it shows the folder dialog for it again. Also check the folder's own permissions. |
| needs a valid API key | The provider rejected the key. Rerun `./install.sh` and paste a new one. |
| cannot read secrets.env | Check `ls -l "~/Library/Application Support/Ramble Flow CLI/secrets.env"`: it must be yours, mode 600. |
| waiting for the provider's rate limit / quota | Free tiers have limits; it waits. For quota or billing, check the provider's console. |
| waiting for the internet | It retries automatically. |
| a recording needs attention | `ramble-flow list`, then `ramble-flow retry <id>`. "uncertain-outcome" means a request timed out after sending; retrying may be billed again. |
| background process: not loaded | It was switched off (System Settings › General › Login Items & Extensions) or uninstalled. Rerun `./install.sh`. |
| `~/Applications/Ramble Flow.app already exists and is a different app` | That is the separate Ramble Flow window app. The installer never replaces it: quit and move it, or install elsewhere with `RAMBLE_FLOW_APP_DIR=<folder> ./install.sh`. |
| I canceled the folder dialog | Nothing was started. Run `./install.sh` again; Enter keeps every answer. |

**A recording isn't transcribed.** It must be recorded after setup and appear in Voice Memos on
this Mac. Recordings wait until the file stops changing (about 20–30 s). Recordings in Recently
Deleted are skipped. A recording whose date could not be established waits for
`ramble-flow approve <id>` or `skip <id>`.

**I edited a recording after its transcript was saved.** v1 does not re-transcribe it.

**I deleted a transcript file.** It is not recreated, and the recording is not sent again.

**Pause**: `ramble-flow pause` (the tool inside the app) stops uploads (the process keeps running); `ramble-flow resume`.
