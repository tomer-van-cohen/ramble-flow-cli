# Contributing

Thanks for helping. Ramble Flow is small on purpose: one job (new Voice Memos → text files), done
reliably and quietly, from the terminal.

## Build and test

```sh
./scripts/test.sh        # unit and integration tests (synthetic audio, mock HTTP)
./scripts/e2e.sh         # end-to-end: real app + launchd agent in a temporary HOME, loopback mock provider
./scripts/check-repo.sh  # repository hygiene (no keys, home paths, audio or runtime output)
```

Requirements: macOS 14+, Swift 5.10+ (the Command Line Tools are enough). `e2e.sh` takes a few
minutes (it synthesizes and processes a 62-minute recording) and cleans up after itself: it uses a
temporary HOME, a separate test bundle id and a unique `.test` LaunchAgent label, and removes them
at the end. It cannot click the folder dialog (macOS forbids that for sandboxed apps); it records
the grants with a test-only helper instead, so the real dialog is a manual test.

## Ground rules

- **No real data in the repository.** No real recordings, transcripts, titles, names, emails,
  keys or account details. Tests use synthetic audio (AVFoundation tones, macOS `say`) and mock
  HTTP.
- **No calls to real providers in tests or CI.** Live checks are manual and deliberate
  ([docs/MANUAL-TESTS.md](docs/MANUAL-TESTS.md)).
- **Behavior over shape.** A test should fail if a user-visible promise breaks: no duplicate
  uploads, nothing old uploaded, nothing overwritten, no key in logs.
- Provider hosts stay fixed in code; no configurable endpoints. The loopback redirect exists only
  in builds compiled with `-DRAMBLE_FLOW_TEST_HOOKS`, which refuse to run without a `.test` label.
- Never write to, rename or delete anything in the Voice Memos folder.
- Logs carry states, short hashed references, HTTP status codes and timings; never titles,
  transcript text or keys.

## Pull requests

Describe the user-visible change, how you tested it (`./scripts/test.sh`, and `./scripts/e2e.sh`
for anything touching the installer or the background process), and your macOS version and chip.
