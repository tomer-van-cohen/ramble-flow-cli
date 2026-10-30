# Third-party notices

## Bundled code

None. Ramble Flow.app uses only Apple system frameworks (Foundation, AppKit for the folder dialog,
AVFoundation, CoreMedia, CryptoKit) and the SQLite library that ships with macOS. No audio binaries (such as
ffmpeg) are bundled or downloaded, and nothing is fetched at build time: the package has no
dependencies.

Development-only tools: `scripts/e2e.sh` uses macOS's `say`, `afinfo`, `sqlite3`, `expect`,
`curl` and `plutil`, and the `ramble-flow-mock-provider` target in this package. None of them are
installed or needed to use Ramble Flow.

## Code reused from the Ramble Flow app

The transcription core (`Sources/RambleFlowCore`) is adapted from the sandboxed Ramble Flow macOS
app by the same author.

## The Ramble logo (app icon)

`scripts/make-icon.swift` draws the existing Ramble logo (green rounded square with a dark wave),
reproducing the geometry and colors of the approved Ramble app-icon master, and the build turns it
into `AppIcon.icns`. The logo comes from the Ramble product by the same author.

**The logo is not licensed under `LICENSE` (MIT).** All rights are reserved by its owner until
decided otherwise. **Open decision before public release:** whether the logo may be redistributed
in a public repository and under which terms (a separate license, a trademark notice, or replacing
it with a neutral icon for forks).

## Names

"Ramble" and "Ramble Flow" are product names of the author. **Open decision before public
release:** whether the names may be used by forks, and whether a trademark notice is needed.
They are not licensed under `LICENSE`.
