# Security

Please report vulnerabilities privately through GitHub's "Report a vulnerability" (security
advisories) on this repository, not in a public issue. Never include API keys, recordings or
transcripts in a report.

## How the API key is stored

**The key is a plaintext file readable by your user account, protected by file permissions.**

- Location: `~/Library/Application Support/Ramble Flow CLI/secrets.env`, mode `0600`, inside a
  folder with mode `0700`. Written atomically by the installer from hidden terminal input.
- Any program running as your user (and root) can read it. That is the trade-off for never
  showing a macOS prompt: the macOS Keychain ties access to the exact program build, and every
  local rebuild would make macOS ask again, which a background process cannot answer.
- It is never placed in the repository, the transcripts folder, the LaunchAgent plist, logs or
  terminal output (only a masked form such as `gsk_…abcd` is shown).
- `GROQ_API_KEY` / `OPENAI_API_KEY` in the environment override the file for a process started
  with them. The LaunchAgent does not pass your shell's environment, so the background process
  uses the file.
- `./install.sh --uninstall` deletes the file. To rotate a key: revoke it at the provider, then
  rerun `./install.sh` and paste the new one.

## Other design notes

- The key is sent only in the `Authorization` header to the fixed HTTPS host of the provider you
  chose (`api.groq.com` or `api.openai.com`). There is no configurable base URL.
- The background app runs in the App Sandbox. It reaches the recordings folder and the transcripts
  folder only through the grants you give in the macOS folder dialog, plus its own data and log
  folders (a sandbox exception). The entitlement for dialog-chosen folders is read-write
  (`com.apple.security.files.user-selected.read-write`), because the transcripts folder must be
  written and macOS has one such entitlement for the whole app. The recordings folder is saved as a
  read-only bookmark (`securityScopeAllowOnlyReadAccess`), so every later start, including at
  login, gets read access only. During the one run in which you click Grant Access, macOS gives the
  app read-write access to the folder you picked; the code only reads it. It never needs Full Disk Access. The
  command-line tool inside the bundle (`ramble-flow`) is not sandboxed. It only runs when you start
  it (setup, status) and never touches recordings.
- Provider error messages are not stored or shown (only machine-readable codes), because they can
  echo key fragments. Log lines pass through a redactor as a second line of defense.
- Builds with `-DRAMBLE_FLOW_TEST_HOOKS` (used only by `scripts/e2e.sh`) can talk to a loopback
  mock server and can record folder grants without a dialog (via a test-only helper). They use their
  own bundle id (`….test`) and refuse to run unless the LaunchAgent label contains `.test`, so they
  cannot replace a real installation or share its grants. `./install.sh` never builds this variant unless
  `RAMBLE_FLOW_TEST_HOOKS=1` is set.
- Local builds are signed ad hoc (no publisher identity). There is no auto-updater: updates are
  `git pull` and `./install.sh`.
