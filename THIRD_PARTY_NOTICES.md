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

**The logo is not licensed under `LICENSE` (MIT).** All rights are reserved by
Tomer Cohen. You may build and run this repository with it unchanged; forks that publish their
own builds should replace it with their own icon (`scripts/make-icon.swift`).

## Names

"Ramble" and "Ramble Flow" are product names of Tomer Cohen and are not licensed under `LICENSE`.
Forks that publish their own builds should use a different name.
