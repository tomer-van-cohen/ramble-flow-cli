// swift-tools-version: 5.10
import PackageDescription

// Ramble Flow (terminal edition): turns new Apple Voice Memos recordings into text files in the
// background. Set up entirely from the terminal by ./install.sh; no windows, no Dock or menu bar
// icon. The background work runs in a tiny sandboxed app bundle so macOS folder grants (one native
// folder dialog per folder) replace Full Disk Access.
//
//   RambleFlowCore   everything testable without a terminal: discovery, eligibility, job store,
//                    audio preparation, providers, export, configuration, folder grants, worker.
//   RambleFlowCLI    the installer dialog, LaunchAgent handling, access probe, background loop and
//                    the small management commands.
//   RambleFlow       Ramble Flow.app's executable (sandboxed): background loop, access probe and
//                    the folder dialog.
//   ramble-flow      the command-line tool inside the bundle (not sandboxed): setup, status, …
//   ramble-flow-mock-provider
//                    development only: a loopback stand-in for the provider APIs used by the
//                    end-to-end test. Never installed.
let package = Package(
    name: "RambleFlowCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ramble-flow", targets: ["ramble-flow"]),
        .executable(name: "RambleFlow", targets: ["RambleFlowApp"]),
        .executable(name: "ramble-flow-mock-provider", targets: ["RambleFlowMockProvider"]),
    ],
    targets: [
        .target(
            name: "RambleFlowCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "RambleFlowCLI",
            dependencies: ["RambleFlowCore"]
        ),
        .executableTarget(
            name: "ramble-flow",
            dependencies: ["RambleFlowCLI"]
        ),
        .executableTarget(
            name: "RambleFlowApp",
            dependencies: ["RambleFlowCLI", "RambleFlowCore"]
        ),
        .executableTarget(
            name: "RambleFlowMockProvider"
        ),
        .testTarget(
            name: "RambleFlowCoreTests",
            dependencies: ["RambleFlowCore"]
        ),
        .testTarget(
            name: "RambleFlowCLITests",
            dependencies: ["RambleFlowCLI", "RambleFlowCore"]
        ),
    ]
)
