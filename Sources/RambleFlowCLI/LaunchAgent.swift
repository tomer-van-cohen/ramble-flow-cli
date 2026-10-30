import Foundation
import RambleFlowCore

/// The per-user LaunchAgent that keeps `ramble-flow run` going: started at login, restarted if it
/// crashes or is killed, left stopped after a clean exit (another copy already running).
public enum LaunchAgentPlist {
    public static func make(layout: InstallLayout, extraEnvironment: [String: String] = [:]) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": layout.label,
            "ProgramArguments": [
                layout.binary.path, "run",
                "--support-dir", layout.paths.root.path,
                "--log-dir", layout.paths.logs.path,
            ],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "StandardOutPath": layout.paths.logs.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": layout.paths.logs.appendingPathComponent("stderr.log").path,
        ]
        if !extraEnvironment.isEmpty { plist["EnvironmentVariables"] = extraEnvironment }
        return plist
    }

    /// A one-shot job that runs `ramble-flow probe-access` as launchd would run the agent, so macOS
    /// privacy protection judges the installed binary itself (not Terminal, which may have its own
    /// Full Disk Access).
    public static func probe(layout: InstallLayout, source: String, destination: String, output: URL, extraEnvironment: [String: String] = [:]) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": layout.probeLabel,
            "ProgramArguments": [layout.binary.path, "probe-access", "--source", source, "--destination", destination, "--output", output.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LaunchOnlyOnce": true,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        if !extraEnvironment.isEmpty { plist["EnvironmentVariables"] = extraEnvironment }
        return plist
    }

    public static func data(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Environment the test-hooks build passes on to its background process (loopback mock
    /// provider). Empty in a regular build.
    public static func testEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        #if RAMBLE_FLOW_TEST_HOOKS
        var values: [String: String] = [:]
        for name in ["RAMBLE_FLOW_LABEL", "RAMBLE_FLOW_TEST_PROVIDER_PORT", "RAMBLE_FLOW_TEST_SCAN_INTERVAL", "RAMBLE_FLOW_TEST_STABILITY_WINDOW"] {
            if let value = environment[name] { values[name] = value }
        }
        return values
        #else
        return [:]
        #endif
    }
}

public struct AgentState: Equatable, Sendable {
    public var loaded: Bool
    public var running: Bool
    public var pid: Int?
    public var lastExitStatus: String?

    public static let notLoaded = AgentState(loaded: false, running: false, pid: nil, lastExitStatus: nil)
}

/// launchd operations, behind a protocol for tests.
public protocol ServiceManager: AnyObject {
    func state(label: String) -> AgentState
    /// Loads (or reloads) the job from the plist file and starts it.
    func bootstrap(plist: URL, label: String) throws
    func bootout(label: String)
}

public struct LaunchctlError: Error, CustomStringConvertible {
    public var command: String
    public var status: Int32
    public var output: String
    public var description: String { "launchctl \(command) failed (\(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

public final class Launchctl: ServiceManager {
    public init() {}

    var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public func state(label: String) -> AgentState {
        let result = Self.run(["print", "\(domain)/\(label)"])
        guard result.status == 0 else { return .notLoaded }
        return Self.parse(result.output)
    }

    static func parse(_ output: String) -> AgentState {
        var state = AgentState(loaded: true, running: false, pid: nil, lastExitStatus: nil)
        // Only the service's own top-level properties (one tab deep); nested sections such as
        // endpoints or event triggers have "state = active" lines of their own.
        for raw in output.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("state = ") { state.running = line == "state = running" }
            if line.hasPrefix("pid = "), let pid = Int(line.dropFirst(6)) { state.pid = pid }
            if line.hasPrefix("last exit code = ") { state.lastExitStatus = String(line.dropFirst(17)) }
        }
        return state
    }

    public func bootstrap(plist: URL, label: String) throws {
        bootout(label: label)
        _ = Self.run(["enable", "\(domain)/\(label)"])
        var last = (status: Int32(0), output: "")
        // Right after a bootout launchd can briefly refuse a new bootstrap ("Input/output error").
        for _ in 0..<10 {
            last = Self.run(["bootstrap", domain, plist.path])
            if last.status == 0 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw LaunchctlError(command: "bootstrap", status: last.status, output: last.output)
    }

    public func bootout(label: String) {
        let result = Self.run(["bootout", "\(domain)/\(label)"])
        guard result.status == 0 else { return }
        // Wait until launchd has really let go of the job.
        for _ in 0..<40 {
            if Self.run(["print", "\(domain)/\(label)"]).status != 0 { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
