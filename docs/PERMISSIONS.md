# Permissions and folder access

## What you approve

| What | When | How |
| --- | --- | --- |
| **Read your Voice Memos recordings folder** | first install | macOS folder dialog, already at `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`: click **Grant Access** |
| **Write to your transcripts folder** | first install, and when you pick another transcripts folder | second folder dialog, already at that folder (or its parent, if the `Ramble Flow` folder does not exist yet): click **Grant Access** |
| Background item | first install | macOS shows "Background Items Added" for Ramble Flow; nothing to click |

That is all: no Full Disk Access, no System Settings, no password, no `sudo`. No microphone,
screen recording, Accessibility, Automation, Contacts or Keychain access is used.

## How it works

The background work runs in a tiny app bundle, `~/Applications/Ramble Flow.app`, with no user
interface (`LSUIElement`: no Dock icon, no menu bar item, no windows). The app runs in the **App
Sandbox**, so it can reach only:

- its own data folders, `~/Library/Application Support/Ramble Flow CLI/` and
  `~/Library/Logs/Ramble Flow CLI/` (a sandbox exception in its entitlements, so the terminal
  installer and the app share settings and the key file);
- folders you choose in the standard macOS folder dialog.

When you click **Grant Access**, macOS grants the app that folder, and the app saves an
*app-scoped security-scoped bookmark* (`grants.json`: the folder path plus opaque bookmark data).
At every later start, including at login from launchd, the app turns the bookmark back into access.
The recordings folder is bookmarked read-only (`securityScopeAllowOnlyReadAccess`), so from the
next start on, macOS gives the app read access to it only. The entitlement itself is
`user-selected.read-write`, because the transcripts folder must be written and the entitlement
applies to the whole app; in the single run where you click Grant Access, the picked recordings
folder is briefly read-write to the app, and the code only reads it.

Choosing the folder yourself in the macOS dialog is also what macOS's privacy protection accepts
for the Voice Memos folder. A program without that grant (or Full Disk Access) gets "Operation not
permitted" there.

The installer checks access **as the background app**: it runs the app's `probe-access` as a
one-shot launchd job (label `<label>.access-probe`). That job counts the files in the recordings
folder (never reading names or contents) and creates and deletes a hidden file in the transcripts
folder. Only when both work does the installer start the background app and say "Done".

## Why a second dialog for the transcripts folder

The sandbox refuses every folder outside the app's own data, Documents and Google Drive included.
So the transcripts folder needs a grant too. Granting it in the dialog also covers macOS's own
protection of Documents and of Google Drive (File Provider), so no further prompt appears. When you
later choose another transcripts folder, only that folder's dialog is shown.

## Rebuilds and upgrades

Every build is signed ad hoc on your Mac, so a new build has a new code identity. The bundle id
stays `io.github.tomer-van-cohen.ramble-flow-cli`.

- Rerunning `./install.sh` from the same checkout keeps the installed app untouched (same bytes, or
  same sources and Swift version), so nothing changes.
- After `git pull` brings new code, the app is replaced. App-scoped bookmarks made by an earlier
  build were still accepted by a differently signed build with the same bundle id in testing (see
  below). If they ever are not, the access check reports "no longer granted" and the installer simply
  shows the dialog again.

## Cancel

If you cancel a dialog, the installer says so, starts nothing, and keeps your answers and key.
Run `./install.sh` again (Enter through the questions) to see the dialog again.

## What was verified (macOS 26.7, Apple silicon)

Automated, with synthetic folders:

- A sandboxed, ad-hoc-signed app is refused when listing a synthetic folder outside its container
  (`NSFileReadNoPermissionError`, 257).
- The same app, **started by launchd** (parent pid 1, inside its sandbox container), resolves an
  app-scoped bookmark to that folder and lists it.
- The bookmark was made by a **differently signed build** with the same bundle id (different code
  hash), so a rebuild keeps the grant.
- `scripts/e2e.sh` runs the whole installer and background app this way:
  - A *grant helper* records the grants: the same app plus a test-only sandbox exception, because
    macOS refuses programmatic answers to a sandboxed app's folder dialog
    (`-[NSSavePanel ok:]: not implemented`).
  - The installed app has no exception for the recordings or transcripts folders. It reads and
    writes them only through the bookmarks, from launchd, including after `kill -9` and restart.

Earlier, by hand, on the same Mac (recorded in the project brief): a sandboxed AppKit app showed the
folder dialog at the real Voice Memos `Recordings` folder. Choosing it allowed listing and reading,
and the bookmark restored access after the app was quit and relaunched, with no Full Disk Access.

## Not verified yet (needs a person at the Mac)

- Clicking **Grant Access** in this app's dialog for the real Voice Memos folder, then the
  launchd-started app reading it. That is the first step of [MANUAL-TESTS.md](MANUAL-TESTS.md).
- That clicking **Grant Access** with nothing selected chooses the folder the dialog shows (standard
  AppKit behavior; if the button is dimmed, select the folder first).
- Writing into a real Google Drive folder granted in the dialog.
- Logout/login and reboot (the LaunchAgent is a standard per-user agent with `RunAtLoad`).
