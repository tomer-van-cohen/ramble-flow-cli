import Darwin
import Foundation
import RambleFlowCore

/// What the background process can do with the two folders. Recording names and contents are
/// never read or reported: only a count.
public struct AccessReport: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case ok
        /// macOS privacy protection refused to list the folder (no Full Disk Access).
        case denied
        case missing
    }

    public enum Destination: String, Codable, Sendable {
        case ok
        case denied
        /// The folder and its parent are both missing.
        case missing
        case notWritable
    }

    public var source: Source
    public var recordings: Int?
    public var destination: Destination
    public var destinationCreated: Bool
    public var errno: Int32?

    public init(source: Source, recordings: Int?, destination: Destination, destinationCreated: Bool, errno: Int32? = nil) {
        self.source = source
        self.recordings = recordings
        self.destination = destination
        self.destinationCreated = destinationCreated
        self.errno = errno
    }
}

public enum AccessProbe {
    /// Runs in the process whose access is being tested.
    public static func run(source: URL, destination: URL) -> AccessReport {
        var report = AccessReport(source: .missing, recordings: nil, destination: .missing, destinationCreated: false)
        switch PathProbe.directoryStatus(source) {
        case .accessible:
            report.source = .ok
            report.recordings = (try? VoiceMemosSource.listRecordings(in: source))?.count
            if report.recordings == nil { report.source = .denied }
        case .denied:
            report.source = .denied
            report.errno = EPERM
        case .missing, .notDirectory:
            report.source = .missing
        }

        let fm = FileManager.default
        if !PathProbe.isDirectory(destination) {
            if PathProbe.isDirectory(destination.deletingLastPathComponent()) {
                do {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                    report.destinationCreated = true
                } catch {
                    let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
                    report.destination = (code == Int(EPERM) || code == Int(EACCES)) ? .denied : .notWritable
                    return report
                }
            } else {
                report.destination = .missing
                return report
            }
        }
        // A real write: create and delete a hidden file of our own.
        let probe = destination.appendingPathComponent(".ramble-flow-write-check-\(UUID().uuidString)")
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd < 0 {
            report.destination = (errno == EPERM || errno == EACCES) ? .denied : .notWritable
            return report
        }
        let ok = Darwin.write(fd, "ok", 2) == 2
        close(fd)
        unlink(probe.path)
        report.destination = ok ? .ok : .notWritable
        return report
    }
}

/// Runs the probe in a context macOS attributes to the installed binary.
public protocol AccessVerifier: AnyObject {
    func verify(source: URL, destination: URL) -> AccessReport?
}

/// Starts `ramble-flow probe-access` as a one-shot launchd job and reads its JSON answer.
public final class LaunchdAccessVerifier: AccessVerifier {
    let layout: InstallLayout
    let service: ServiceManager
    let timeout: TimeInterval

    public init(layout: InstallLayout, service: ServiceManager, timeout: TimeInterval = 20) {
        self.layout = layout
        self.service = service
        self.timeout = timeout
    }

    public func verify(source: URL, destination: URL) -> AccessReport? {
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
        let plist = LaunchAgentPlist.probe(layout: layout, source: source.path, destination: destination.path, output: output,
                                           extraEnvironment: LaunchAgentPlist.testEnvironment())
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
