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
- The program is not sandboxed. It needs Full Disk Access, which macOS grants per program: it
  reads only the recordings folder you chose (never writing there) and writes only to your
  transcripts folder and its own folders in `~/Library`.
- Provider error messages are not stored or shown (only machine-readable codes), because they can
  echo key fragments. Log lines pass through a redactor as a second line of defense.
- Builds with `-DRAMBLE_FLOW_TEST_HOOKS` (used only by `scripts/e2e.sh`) can talk to a loopback
  mock server. They refuse to run unless the LaunchAgent label contains `.test`, so they cannot
  replace a real installation. `./install.sh` never builds this variant unless
  `RAMBLE_FLOW_TEST_HOOKS=1` is set.
- Local builds are signed ad hoc (no publisher identity). There is no auto-updater: updates are
  `git pull` and `./install.sh`.
