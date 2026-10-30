import Foundation

/// Access to a folder. Kept as a protocol so the worker can be exercised against test folders and
/// so every use is bracketed in one place.
public protocol FolderAccess: Sendable {
    var url: URL { get }
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
    func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T
}

/// A plain folder path. The command-line tool is not sandboxed: what it may read is decided by
/// macOS privacy protection (Full Disk Access for the Voice Memos folder), not by bookmarks.
public struct PlainFolderAccess: FolderAccess {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
    public func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T { try await body(url) }
}

/// Resolves the configured folders for the worker, telling "no permission" apart from "gone".
public enum ConfiguredFolders {
    /// The recordings folder. `denied` means macOS refused to list it (usually: no Full Disk
    /// Access for this binary); `missing` means it does not exist.
    public static func source(_ config: AppConfig) -> FolderAvailability {
        guard let path = config.sourcePath else { return .notGranted("not-configured") }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        switch PathProbe.directoryStatus(url) {
        case .accessible: return .available(PlainFolderAccess(url: url))
        case .denied: return .notGranted("denied")
        case .missing, .notDirectory: return .notGranted("missing")
        }
    }

    /// The transcripts folder. If only the dedicated "Ramble Flow" folder was removed while its
    /// parent is still there, it is created again. If the parent is gone too (Google Drive quit or
    /// signed out, a disk unplugged), results wait: transcripts are never written anywhere else.
    public static func destination(_ config: AppConfig) -> FolderAvailability {
        guard let path = config.destinationPath else { return .notGranted("not-configured") }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var status = PathProbe.directoryStatus(url)
        if status == .missing, PathProbe.isDirectory(url.deletingLastPathComponent()) {
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil {
                status = PathProbe.directoryStatus(url)
            }
        }
        switch status {
        case .accessible:
            return PathProbe.isWritableDirectory(url) ? .available(PlainFolderAccess(url: url)) : .notGranted("denied")
        case .denied: return .notGranted("denied")
        case .missing, .notDirectory: return .notGranted("missing")
        }
    }
}
