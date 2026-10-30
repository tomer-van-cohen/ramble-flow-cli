// swift-tools-version: 5.10
import PackageDescription

// Ramble Flow (command line): a background process that turns new Apple Voice Memos recordings into
// text files. No app bundle, no windows, no SwiftUI: a single binary started by a per-user
// LaunchAgent, configured by ./install.sh.
//
//   RambleFlowCore   everything testable without a terminal: discovery, eligibility, job store,
//                    audio preparation, providers, export, configuration, the worker.
//   RambleFlowCLI    the installer dialog, LaunchAgent handling, access probe, background loop and
//                    the small `ramble-flow` subcommands.
//   ramble-flow      the executable (a thin entry point).
//   ramble-flow-mock-provider
//                    development only: a loopback stand-in for the provider APIs used by the
//                    end-to-end test. Never installed.
let package = Package(
    name: "RambleFlowCLI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ramble-flow", targets: ["ramble-flow"]),
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
