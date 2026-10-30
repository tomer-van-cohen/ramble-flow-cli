# Troubleshooting

Start with `ramble-flow status` (in `~/.local/bin`). `ramble-flow list` shows recordings that need
you; `ramble-flow logs` the end of the log.

| Status says | What to do |
| --- | --- |
| watching | All good. Nothing to transcribe yet is normal. |
| cannot read the recordings folder: grant Full Disk Access | Run `./install.sh` again; it guides you and verifies. After a `git pull` that changed the program, remove the old `ramble-flow` entry in Full Disk Access with − and add it again. |
| recordings folder not found | Turn on iCloud for Voice Memos on the iPhone and this Mac (same Apple Account) and open Voice Memos on the Mac once. |
| starting (waiting to read the recordings folder) | The cutoff is set the first time the folder can be read. Same fix as above. |
| transcripts folder unavailable | Google Drive quit or signed out, a disk unplugged, or the folder's parent was removed. Results wait and are saved when it is back; never elsewhere. To use another folder, rerun `./install.sh`. |
| cannot write to the transcripts folder | Check its permissions; if it is in Google Drive and macOS asked about access to files, allow it. |
| needs a valid API key | The provider rejected the key. Rerun `./install.sh` and paste a new one. |
| cannot read secrets.env | Check `ls -l "~/Library/Application Support/Ramble Flow CLI/secrets.env"`: it must be yours, mode 600. |
| waiting for the provider's rate limit / quota | Free tiers have limits; it waits. For quota or billing, check the provider's console. |
| waiting for the internet | It retries automatically. |
| a recording needs attention | `ramble-flow list`, then `ramble-flow retry <id>`. "uncertain-outcome" means a request timed out after sending; retrying may be billed again. |
| background process: not loaded | It was switched off (System Settings › General › Login Items & Extensions) or uninstalled. Rerun `./install.sh`. |

**A recording isn't transcribed.** It must be recorded after setup and appear in Voice Memos on
this Mac. Recordings wait until the file stops changing (about 20–30 s). Recordings in Recently
Deleted are skipped. A recording whose date could not be established waits for
`ramble-flow approve <id>` or `skip <id>`.

**I edited a recording after its transcript was saved.** v1 does not re-transcribe it.

**I deleted a transcript file.** It is not recreated, and the recording is not sent again.

**Pause**: `ramble-flow pause` stops uploads (the process keeps running); `ramble-flow resume`.
