import Foundation
import RambleFlowCore

public enum Product {
    public static let name = "Ramble Flow"
    public static let binaryName = "ramble-flow"
    /// Reverse-DNS label of the LaunchAgent. Independent of the sandboxed Ramble Flow app, so the
    /// two never share settings or background jobs.
    public static let defaultLabel = "io.github.tomer-van-cohen.ramble-flow-cli"
    /// Code-signing identifier given to the locally built binary.
    public static let signingIdentifier = "io.github.tomer-van-cohen.ramble-flow-cli"
    public static let supportFolderName = "Ramble Flow CLI"
    public static let transcriptsFolderName = FolderLocator.destinationFolderName

    public static var version: String {
        #if RAMBLE_FLOW_TEST_HOOKS
        return versionString + " (test hooks)"
        #else
        return versionString
        #endif
    }

    static let versionString = "0.1.0"

    public static var testHooksCompiled: Bool {
        #if RAMBLE_FLOW_TEST_HOOKS
        return true
        #else
        return false
        #endif
    }
}

/// Where everything lives. Derived from `$HOME`, so the whole installation can be exercised
/// against a temporary home folder. Two environment variables exist for tests and unusual setups:
///
/// - `RAMBLE_FLOW_LABEL`: LaunchAgent label (launchd's namespace is per user, not per home).
/// - `RAMBLE_FLOW_BIN_DIR`: folder of the installed binary (default `~/.local/bin`).
public struct InstallLayout: Sendable {
    public var home: URL
    public var label: String
    public var binary: URL
    public var paths: AppPaths
    public var launchAgents: URL

    public var plist: URL { launchAgents.appendingPathComponent("\(label).plist") }
    /// One-shot launchd job used to check access *as the background process*.
    public var probeLabel: String { "\(label).access-probe" }
    public var logFile: URL { paths.logs.appendingPathComponent("ramble-flow.log") }

    public init(home: URL, label: String, binary: URL, paths: AppPaths, launchAgents: URL) {
        self.home = home
        self.label = label
        self.binary = binary
        self.paths = paths
        self.launchAgents = launchAgents
    }

    public enum LayoutError: Error, CustomStringConvertible {
        case invalidLabel(String)
        case testBuildNeedsTestLabel

        public var description: String {
            switch self {
            case .invalidLabel(let label): return "invalid RAMBLE_FLOW_LABEL: \(label)"
            case .testBuildNeedsTestLabel:
                return "this is a test-hooks build; it only runs with a RAMBLE_FLOW_LABEL that contains \".test\""
            }
        }
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> InstallLayout {
        let home = RealHome.url
        let label = environment["RAMBLE_FLOW_LABEL"].flatMap { $0.isEmpty ? nil : $0 } ?? Product.defaultLabel
        guard label.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*$"#, options: .regularExpression) != nil else {
            throw LayoutError.invalidLabel(label)
        }
        #if RAMBLE_FLOW_TEST_HOOKS
        // A build that can talk to a loopback mock must never take the real installation's place.
        guard label.contains(".test") else { throw LayoutError.testBuildNeedsTestLabel }
        #endif
        let binDir = environment["RAMBLE_FLOW_BIN_DIR"].flatMap { $0.isEmpty ? nil : PathDisplay.expand($0, home: home) }
            ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let paths = AppPaths(
            root: library.appendingPathComponent("Application Support/\(Product.supportFolderName)", isDirectory: true),
            logs: library.appendingPathComponent("Logs/\(Product.supportFolderName)", isDirectory: true))
        return InstallLayout(home: home, label: label, binary: binDir.appendingPathComponent(Product.binaryName),
                             paths: paths, launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true))
    }

    /// `KEY='value'` lines for the installer script.
    public func shellAssignments() -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let values: [(String, String)] = [
            ("RF_LABEL", label),
            ("RF_BINARY", binary.path),
            ("RF_SUPPORT", paths.root.path),
            ("RF_LOGS", paths.logs.path),
            ("RF_PLIST", plist.path),
            ("RF_PROBE_LABEL", probeLabel),
            ("RF_SECRETS", paths.secrets.path),
        ]
        return values.map { "\($0.0)=\(quote($0.1))" }.joined(separator: "\n")
    }
}
