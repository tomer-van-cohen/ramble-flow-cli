# Third-party notices

## Bundled code

None. The `ramble-flow` program uses only Apple system frameworks (Foundation, AVFoundation,
CoreMedia, CryptoKit) and the SQLite library that ships with macOS. No audio binaries (such as
ffmpeg) are bundled or downloaded, and nothing is fetched at build time: the package has no
dependencies.

Development-only tools: `scripts/e2e.sh` uses macOS's `say`, `afinfo`, `sqlite3`, `expect`,
`curl` and `plutil`, and the `ramble-flow-mock-provider` target in this package. None of them are
installed or needed to use Ramble Flow.

## Code reused from the Ramble Flow app

The transcription core (`Sources/RambleFlowCore`) is adapted from the sandboxed Ramble Flow macOS
app by the same author. No design assets, logos or icons are included in this repository.

## Names

"Ramble" and "Ramble Flow" are product names of the author. **Open decision before public
release:** whether the names may be used by forks, and whether a trademark notice is needed.
They are not licensed under `LICENSE`.
