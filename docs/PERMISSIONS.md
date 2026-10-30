# Permissions

## What is needed, and why

| Permission | Needed? | Why |
| --- | --- | --- |
| **Full Disk Access** for `~/.local/bin/ramble-flow` | Yes | macOS protects the Voice Memos folder (`~/Library/Group Containers/group.com.apple.VoiceMemos.shared`). A program without Full Disk Access gets "Operation not permitted" when it lists it. |
| Access to files in Google Drive | Maybe | If your transcripts folder is in Google Drive, macOS may ask once whether `ramble-flow` may access files in Google Drive (File Provider). Allow it. |
| Background item / login item | Automatic | Adding the LaunchAgent makes macOS show "Background Items Added". If you switch `ramble-flow` off in System Settings › General › Login Items & Extensions, it stops. |
| Microphone, screen recording, Accessibility, Automation, Contacts, Keychain | No | None of these are used. |

No `sudo`, no system-wide changes: everything lives in your home folder.

## Why the program itself needs it (not Terminal)

macOS decides access per *responsible program*. When you run a command in Terminal, Terminal is
responsible, so a Terminal that already has Full Disk Access would make everything look fine. The
background process is started by launchd, so `ramble-flow` itself is responsible, and it needs its
own entry in the Full Disk Access list.

That is why the installer checks access **as the background process**: it starts
`ramble-flow probe-access` as a one-shot launchd job (label `<label>.access-probe`), which lists the
recordings folder (counting files, never reading names or contents) and creates and deletes a
hidden file in the transcripts folder. Only when that succeeds does it say "ok". The job is
unloaded and its files removed right after.

## The installer's steps

1. It runs the check. If the recordings folder is refused, it opens
   **System Settings › Privacy & Security › Full Disk Access**
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) and reveals
   `ramble-flow` in Finder (`open -R`).
2. You drag `ramble-flow` into the list (or click **+**, press ⌘⇧G, paste the path shown) and make
   sure its switch is on. macOS asks for your password.
3. You press Enter; it checks again. `s` skips: the process starts but waits, uploading nothing,
   until access works. `o` opens System Settings and Finder again.

Set `RAMBLE_FLOW_NO_OPEN=1` to have the installer print the `open` commands instead of running
them (for example over SSH).

## Rebuilds and upgrades

The program is signed ad hoc on your Mac, so macOS ties Full Disk Access to its exact bytes.

- Rerunning `./install.sh` from the same checkout keeps the installed program untouched (same
  bytes, or same sources and Swift version), so the permission stays valid.
- After `git pull` brings new code, the program changes and macOS treats it as a new program. The
  installer says so: remove the old `ramble-flow` entry with **−**, add the new one, switch it on.
  It verifies before finishing. Until then the process waits; nothing is lost.

## What was verified (macOS 26.7, Apple silicon)

- A `ramble-flow` binary started by launchd, without Full Disk Access, is refused when listing the
  real Voice Memos `Recordings` folder (`EPERM`); the probe reports it as "not permitted", and
  `stat` still tells "exists" apart from "missing".
- The whole installer flow, including the denied → granted → verified loop, was exercised end to
  end with a synthetic recordings folder whose permissions were removed and restored
  (`scripts/e2e.sh`), with the real launchd.

## Not verified (needs a person at the Mac)

- Granting Full Disk Access in System Settings and seeing the probe then succeed on the real
  Voice Memos folder. (Granting it was deliberately not done during development.)
- That the System Settings URL above opens the Full Disk Access pane on every macOS version.
- Whether writing into a Google Drive folder from the background process shows a File Provider
  prompt, and whether Full Disk Access already covers it.
- Behavior after logout/login and reboot (the LaunchAgent is a standard per-user agent with
  `RunAtLoad`).
- Re-granting after an upgrade (removing and re-adding the entry), as described above.

Steps for all of these: [MANUAL-TESTS.md](MANUAL-TESTS.md).
