# Manual tests

Automated tests cannot grant macOS permissions or spend provider credit. These steps cover what
they cannot. Use synthetic or throwaway recordings; never paste real transcripts into issues.

Record for each run: macOS version, chip, `swift --version`, `ramble-flow version`
(`~/Applications/Ramble Flow.app/Contents/MacOS/ramble-flow version`).

## 1. Fresh install: the folder dialogs on the real Voice Memos folder (most important)

1. `git clone …`, `cd`, `./install.sh`. Press Enter at every question except the API key.
2. Expect "two standard macOS folder dialogs". The first shows Voice Memos' `Recordings` folder
   (title "Ramble Flow"): click **Grant Access**. (If the button is dimmed, select the folder
   first; please note it.) The second shows the transcripts folder or its parent: click **Grant
   Access**.
3. Expect, after "Checking again as the background app…":
   "Recordings folder ok (N recordings there now; none of them will be uploaded)" and
   "Transcripts folder ok", then "Running (pid …)" and "Watching for recordings made after …".
   This is the proof that the launchd-started, sandboxed app reads the real Voice Memos folder
   through the bookmark, without Full Disk Access.
4. No Dock icon, no menu bar item, no window remains. `./install.sh --status`: running, watching,
   both folders "(granted)", the cutoff.
5. `"$HOME/Applications/Ramble Flow.app/Contents/MacOS/ramble-flow" list --all`: existing recordings
   are `excluded`.
6. Cancel path: `./install.sh --uninstall --yes`, then `./install.sh`, Enter everywhere, and
   click **Cancel** in the first dialog. Expect "You canceled the folder dialog…", nothing
   started (`--status`: not loaded). Run `./install.sh` again and grant.

## 2. Live transcription, one provider at a time (spends a little credit)

1. Record a 10–20 second memo on the iPhone (Voice Memos, iCloud on). Say something invented.
2. Wait for it to appear in Voice Memos on the Mac, then about 30 s more.
3. A file `YYYY-MM-DD HH-MM-SS — <title> — <id>.txt` appears in the transcripts folder. Check the
   header (title, recorded time with offset, duration, `Groq / whisper-large-v3`) and the text.
4. `ramble-flow logs` (the tool inside the app): no title, no transcript text, no key.
5. OpenAI: rerun `./install.sh`, answer `2`, paste an OpenAI key, Enter elsewhere. Repeat 1–3; the
   header says `OpenAI / gpt-transcribe`.
6. Optional: a Hebrew memo, a mixed Hebrew/English memo, a silent memo (`[No speech detected]`).

## 3. Long recording (spends more credit: about one hour of audio)

1. Record (or let run) a memo longer than 31 minutes.
2. Expect several requests in the log (`planned N request(s)`), one transcript file.
3. While it is uploading, `kill -9 $(pgrep -f "RambleFlow run")`. launchd restarts it within
   ~10 s; the log shows the job resuming; finished parts are not sent again.

## 4. Lifecycle

1. Log out and back in: `ramble-flow status` shows running; no window or prompt appears.
2. Reboot: same. Record a memo while the Mac sleeps; it is transcribed after wake.
3. System Settings › General › Login Items & Extensions: "Ramble Flow" is listed under "Allow in
   the Background". Switching it off stops the process (`status`: not loaded); `./install.sh`
   brings it back.

## 5. Changing settings and upgrading

1. Rerun `./install.sh`: every question shows the current value; Enter everywhere changes
   nothing, shows no dialog, says "App unchanged" and keeps the pid.
2. Change the transcripts folder: exactly one dialog (for the new folder); the next memo goes
   there; old files stay where they were.
3. Upgrade: make a trivial source change (or `git pull` a new version), rerun `./install.sh`.
   Expect "This checkout builds a new version of the app". Expected: no dialog (the grants survive
   the rebuild, as in the automated test). If a dialog does appear, grant again and note it.

## 6. Google Drive

1. With Google Drive for desktop signed in, the default transcripts folder is
   `…/GoogleDrive-<account>/My Drive/Ramble Flow`; the second dialog opens at My Drive. Note
   whether macOS shows any additional prompt (expected: none, the dialog is the consent).
2. Quit Google Drive: `--status` says the transcripts folder is unavailable after the next memo;
   restart Drive; the transcript is saved; nothing is written elsewhere.

## 7. Uninstall

1. `./install.sh --uninstall`, Enter, Enter (keep data). `--status` says not installed; the
   plist, `~/Applications/Ramble Flow.app`, `secrets.env` and `grants.json` are gone; recordings and
   transcripts are intact.
2. `./install.sh` again: the cutoff is the old one (data was kept); the dialogs appear again
   (grants were removed).
3. `./install.sh --uninstall --yes --purge` removes settings, history and logs too. The sandbox
   container stays (macOS protects it); drag it to the Trash in Finder.
