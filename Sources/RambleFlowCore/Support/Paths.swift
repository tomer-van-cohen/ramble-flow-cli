import Darwin
import Foundation

/// The user's home folder: `$HOME` when set (so tests and the installer can run against a
/// temporary home), otherwise the user database entry.
public enum RealHome {
    public static var url: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty, home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// Private storage of the background process. Nothing here is ever written next to the user's
/// recordings or transcripts.
public struct AppPaths: Sendable {
    /// `~/Library/Application Support/Ramble Flow CLI` (mode 0700).
    public let root: URL
    /// `~/Library/Logs/Ramble Flow CLI`.
    public let logs: URL

    public init(root: URL, logs: URL? = nil) {
        self.root = root
        self.logs = logs ?? root.appendingPathComponent("Logs", isDirectory: true)
    }

    public var database: URL { root.appendingPathComponent("jobs.sqlite") }
    public var config: URL { root.appendingPathComponent("config.json") }
    /// API keys, plaintext, mode 0600. See `KeyFileStore`.
    public var secrets: URL { root.appendingPathComponent("secrets.env") }
    /// Last status written by the background process, for `ramble-flow status`.
    public var status: URL { root.appendingPathComponent("status.json") }
    public var work: URL { root.appendingPathComponent("Work", isDirectory: true) }
    public var lock: URL { root.appendingPathComponent("worker.lock") }

    public func workDirectory(forJob id: Int64) -> URL {
        work.appendingPathComponent("job-\(id)", isDirectory: true)
    }

    /// Creates the folders: the private root and its work folder owner-only (0700).
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [root, work] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(dir.path, 0o700)
        }
        try fm.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// What a path looks like from this process: present and readable, present but refused, or absent.
/// The distinction matters: "not found" must never be reported when access was merely denied
/// (macOS privacy protection answers `EPERM` for the Voice Memos folder without Full Disk Access).
public enum PathStatus: String, Codable, Sendable, Equatable {
    case accessible
    case denied
    case missing
    case notDirectory
}

public enum PathProbe {
    /// `stat` succeeds for a protected folder that cannot be listed, which is how
    /// "exists but needs permission" is told apart from "does not exist".
    public static func directoryStatus(_ url: URL) -> PathStatus {
        var info = stat()
        if stat(url.path, &info) != 0 {
            return (errno == EACCES || errno == EPERM) ? .denied : .missing
        }
        if (info.st_mode & S_IFMT) != S_IFDIR { return .notDirectory }
        guard let dir = opendir(url.path) else {
            return (errno == ENOENT) ? .missing : .denied
        }
        closedir(dir)
        return .accessible
    }

    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    public static func isWritableDirectory(_ url: URL) -> Bool {
        isDirectory(url) && access(url.path, W_OK) == 0
    }
}

public enum PathDisplay {
    /// `~/…` for paths in the home folder.
    public static func tilde(_ url: URL, home: URL = RealHome.url) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// Expands a leading `~` and makes relative paths absolute against `base`. Accepts paths
    /// dragged from Finder into Terminal (quoted, or with backslash-escaped spaces).
    public static func expand(_ input: String, home: URL = RealHome.url, base: URL? = nil) -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, (text.hasPrefix("'") && text.hasSuffix("'")) || (text.hasPrefix("\"") && text.hasSuffix("\"")) {
            text = String(text.dropFirst().dropLast())
        } else if text.contains("\\") {
            text = text.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        }
        if text == "~" { return home }
        if text.hasPrefix("~/") { return home.appendingPathComponent(String(text.dropFirst(2)), isDirectory: true).standardizedFileURL }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text, isDirectory: true).standardizedFileURL }
        let root = base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return root.appendingPathComponent(text, isDirectory: true).standardizedFileURL
    }
}
