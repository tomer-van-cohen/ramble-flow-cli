import Darwin
import Foundation
import RambleFlowCore

/// What the background app can do with the two folders, judged from inside its sandbox with its
/// saved grants. Recording names and contents are never read or reported: only a count.
public struct AccessReport: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case ok
        /// No grant yet, or the grant is for another folder.
        case notGranted
        /// A grant exists but reading is refused (it is no longer valid for this app).
        case denied
        case missing
    }

    public enum Destination: String, Codable, Sendable {
        case ok
        case notGranted
        case denied
        /// The folder is gone (Google Drive offline, a disk unplugged, deleted).
        case missing
    }

    public var source: Source
    public var recordings: Int?
    public var destination: Destination
    /// Whether the probe really ran inside the App Sandbox (evidence for the report).
    public var sandboxed: Bool
    public var detail: String?

    public init(source: Source, recordings: Int? = nil, destination: Destination, sandboxed: Bool = false, detail: String? = nil) {
        self.source = source
        self.recordings = recordings
        self.destination = destination
        self.sandboxed = sandboxed
        self.detail = detail
    }

    public var allOK: Bool { source == .ok && destination == .ok }
}

public enum AccessProbe {
    /// Runs in the process whose access is being tested (the sandboxed app, started by launchd).
    public static func run(paths: AppPaths) -> AccessReport {
        let config = ConfigStore(url: paths.config).current
        let folders = GrantedFolders(grants: GrantStore(url: paths.grants))
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        var report = AccessReport(source: .notGranted, destination: .notGranted, sandboxed: sandboxed)
        var details: [String] = []

        switch folders.source(config) {
        case .available(let folder):
            if let count = try? folder.withAccess({ try VoiceMemosSource.listRecordings(in: $0).count }) {
                report.source = .ok
                report.recordings = count
            } else {
                report.source = .denied
            }
        case .notGranted(let reason):
            details.append("source:\(reason)")
            switch reason {
            case "missing": report.source = .missing
            case "denied": report.source = .denied
            case let r where r.hasPrefix("grant-invalid"): report.source = .denied
            default: report.source = .notGranted
            }
        }

        switch folders.destination(config) {
        case .available(let folder):
            // A real write: create and delete a hidden file of our own.
            let ok = (try? folder.withAccess { dir -> Bool in
                let probe = dir.appendingPathComponent(".ramble-flow-write-check-\(UUID().uuidString)")
                let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { return false }
                let written = Darwin.write(fd, "ok", 2) == 2
                close(fd)
                unlink(probe.path)
                return written
            }) ?? false
            report.destination = ok ? .ok : .denied
        case .notGranted(let reason):
            details.append("destination:\(reason)")
            switch reason {
            case "missing": report.destination = .missing
            case "denied": report.destination = .denied
            case let r where r.hasPrefix("grant-invalid"): report.destination = .denied
            default: report.destination = .notGranted
            }
        }
        report.detail = details.isEmpty ? nil : details.joined(separator: ",")
        return report
    }

    public static func write(_ report: AccessReport, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report) else { return false }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard (try? data.write(to: temporary)) != nil else { return false }
        return rename(temporary.path, url.path) == 0
    }
}

/// Runs the probe in the context the background process will have.
public protocol AccessVerifier: AnyObject {
    func verify() -> AccessReport?
}

/// Starts the app's `probe-access` as a one-shot launchd job and reads its JSON answer.
public final class LaunchdAccessVerifier: AccessVerifier {
    let layout: InstallLayout
    let service: ServiceManager
    let timeout: TimeInterval

    public init(layout: InstallLayout, service: ServiceManager, timeout: TimeInterval = 20) {
        self.layout = layout
        self.service = service
        self.timeout = timeout
    }

    public func verify() -> AccessReport? {
        let fm = FileManager.default
        try? layout.paths.createDirectories()
        let output = layout.paths.root.appendingPathComponent("access-probe.json")
        let plistURL = layout.paths.root.appendingPathComponent("access-probe.plist")
        try? fm.removeItem(at: output)
        defer {
            service.bootout(label: layout.probeLabel)
            try? fm.removeItem(at: plistURL)
            try? fm.removeItem(at: output)
        }
        let plist = LaunchAgentPlist.probe(layout: layout, output: output, extraEnvironment: LaunchAgentPlist.testEnvironment())
        guard let data = try? LaunchAgentPlist.data(plist), (try? data.write(to: plistURL)) != nil else { return nil }
        do {
            try service.bootstrap(plist: plistURL, label: layout.probeLabel)
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: output), let report = try? JSONDecoder().decode(AccessReport.self, from: data) {
                return report
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }
}

// MARK: - Folder dialogs

/// The answer of the folder dialog(s), written by the app to `grant-result.json`.
public struct GrantOutcome: Codable, Equatable, Sendable {
    public struct Answer: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable {
            case granted
            case canceled
            case failed
        }

        public var status: Status
        /// The folder now granted (may differ from the one proposed if the user chose another).
        public var path: String?
        /// The dedicated transcripts folder was created inside the chosen parent.
        public var created: Bool
        public var detail: String?

        public init(status: Status, path: String? = nil, created: Bool = false, detail: String? = nil) {
            self.status = status
            self.path = path
            self.created = created
            self.detail = detail
        }
    }

    public var source: Answer?
    public var destination: Answer?

    public init(source: Answer? = nil, destination: Answer? = nil) {
        self.source = source
        self.destination = destination
    }
}

/// Records a folder chosen in the dialog as an app-scoped bookmark. Runs inside the sandboxed app,
/// while the dialog's grant is in effect.
public enum GrantRecorder {
    public static func recordSource(picked: URL, grants: GrantStore) -> GrantOutcome.Answer {
        do {
            let bookmark = try Bookmarks.create(for: picked, readOnly: true)
            try grants.update { $0.source = FolderGrants.Grant(path: picked.standardizedFileURL.path, bookmark: bookmark) }
            return .init(status: .granted, path: picked.standardizedFileURL.path)
        } catch {
            return .init(status: .failed, detail: "\((error as NSError).domain)#\((error as NSError).code)")
        }
    }

    /// The dialog opens at the proposed transcripts folder, or at its parent when the folder does
    /// not exist yet. Choosing that parent means "create the Ramble Flow folder in here"; choosing
    /// any other folder makes that folder the transcripts folder.
    public static func recordDestination(picked: URL, intended: URL, grants: GrantStore) -> GrantOutcome.Answer {
        let pickedPath = picked.standardizedFileURL.path
        var target = picked.standardizedFileURL
        var created = false
        if GrantedFolders.samePath(pickedPath, intended.deletingLastPathComponent().path) && !GrantedFolders.samePath(pickedPath, intended.path) {
            target = intended.standardizedFileURL
        }
        do {
            if !PathProbe.isDirectory(target) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                created = true
            }
            let bookmark = try Bookmarks.create(for: target, readOnly: false)
            try grants.update { $0.destination = FolderGrants.Grant(path: target.path, bookmark: bookmark) }
            return .init(status: .granted, path: target.path, created: created)
        } catch {
            return .init(status: .failed, detail: "\((error as NSError).domain)#\((error as NSError).code)")
        }
    }

    public static func write(_ outcome: GrantOutcome, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(outcome) { try? data.write(to: url, options: [.atomic]) }
    }
}

/// Shows the folder dialog(s) for whatever still needs a grant.
public protocol FolderGranter: AnyObject {
    func requestGrants(source: URL?, destination: URL?) -> GrantOutcome?
}

/// Opens Ramble Flow.app in grant mode (it shows the native folder dialog, nothing else) and waits
/// for it to finish.
public final class AppFolderGranter: FolderGranter {
    let layout: InstallLayout
    let environment: [String: String]

    public init(layout: InstallLayout, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.layout = layout
        self.environment = environment
    }

    public func requestGrants(source: URL?, destination: URL?) -> GrantOutcome? {
        try? FileManager.default.removeItem(at: layout.paths.grantResult)
        var app = layout.app.path
        var extra: [String] = []
        #if RAMBLE_FLOW_TEST_HOOKS
        // Tests cannot click a sandboxed folder dialog (macOS refuses programmatic answers), so a
        // test-only twin of the app with the same identity records the grants without a dialog.
        if let testApp = environment["RAMBLE_FLOW_TEST_GRANT_APP"] { app = testApp }
        if let mode = environment["RAMBLE_FLOW_TEST_GRANT_MODE"] { extra = ["--test-\(mode)"] }
        #endif
        var arguments = ["-n", "-W", app, "--args", "grant", "--support-dir", layout.paths.root.path]
        if let source { arguments += ["--source", source.path] }
        if let destination { arguments += ["--destination", destination.path] }
        arguments += extra
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: layout.paths.grantResult) else { return nil }
        try? FileManager.default.removeItem(at: layout.paths.grantResult)
        return try? JSONDecoder().decode(GrantOutcome.self, from: data)
    }
}
