import Darwin
import Foundation

/// Access to a folder. Every use is bracketed: for a granted folder, security-scoped access is
/// started before the body runs and stopped after it, including across `await`.
public protocol FolderAccess: Sendable {
    var url: URL { get }
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T
    func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T
}

/// A folder this process can use without a grant (tests, its own folders).
public struct PlainFolderAccess: FolderAccess {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T { try body(url) }
    public func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T { try await body(url) }
}

/// A folder the user granted in the macOS folder dialog, reached through a security-scoped bookmark.
public struct SecurityScopedFolder: FolderAccess {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    public func withAccess<T>(_ body: (URL) async throws -> T) async throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try await body(url)
    }
}

public enum Bookmarks {
    public enum Resolution {
        case resolved(SecurityScopedFolder, refreshedBookmark: Data?)
        /// The bookmark no longer resolves: the folder is gone, its volume is unmounted, or the
        /// grant is not valid for this app any more.
        case unresolvable(String)
    }

    /// A persistent app-scoped bookmark. Call while the URL is accessible (straight after the
    /// folder dialog).
    public static func create(for url: URL, readOnly: Bool) throws -> Data {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ data: Data, readOnly: Bool) -> Resolution {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            let folder = SecurityScopedFolder(url: url)
            var refreshed: Data?
            if stale {
                refreshed = try? folder.withAccess { try create(for: $0, readOnly: readOnly) }
            }
            return .resolved(folder, refreshedBookmark: refreshed)
        } catch {
            let ns = error as NSError
            return .unresolvable("\(ns.domain)#\(ns.code)")
        }
    }
}

/// The two folder grants, stored as app-scoped bookmarks in `grants.json` in the private support
/// folder. Only the sandboxed Ramble Flow app can turn them back into access; the file holds
/// the folder paths and opaque bookmark data, nothing else.
public struct FolderGrants: Codable, Equatable, Sendable {
    public struct Grant: Codable, Equatable, Sendable {
        public var path: String
        public var bookmark: Data
        public var grantedAt: Date

        public init(path: String, bookmark: Data, grantedAt: Date = Date()) {
            self.path = path
            self.bookmark = bookmark
            self.grantedAt = grantedAt
        }
    }

    public var source: Grant?
    public var destination: Grant?

    public init(source: Grant? = nil, destination: Grant? = nil) {
        self.source = source
        self.destination = destination
    }
}

/// Atomic persistence for `FolderGrants`, re-read when another process changed the file.
public final class GrantStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached = FolderGrants()
    private var stamp = ""

    public init(url: URL) {
        self.url = url
        reloadLocked()
    }

    public var current: FolderGrants {
        lock.lock()
        defer { lock.unlock() }
        reloadLocked()
        return cached
    }

    private func fileStamp() -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return "absent" }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)-\(info.st_ino)"
    }

    private func reloadLocked() {
        let current = fileStamp()
        guard current != stamp else { return }
        stamp = current
        if current == "absent" {
            cached = FolderGrants()
        } else if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let grants = try? decoder.decode(FolderGrants.self, from: data) { cached = grants }
        }
    }

    @discardableResult
    public func update(_ change: (inout FolderGrants) -> Void) throws -> FolderGrants {
        lock.lock()
        defer { lock.unlock() }
        reloadLocked()
        var next = cached
        change(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(next).write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
        cached = next
        stamp = fileStamp()
        return next
    }
}

/// Resolves the granted folders for the worker, telling "no grant" apart from "gone" and from
/// "refused". Resolutions are cached per bookmark; a refreshed (stale) bookmark is saved back.
public final class GrantedFolders: @unchecked Sendable {
    private let grants: GrantStore
    private let lock = NSLock()
    private var cache: [Data: URL] = [:]

    public init(grants: GrantStore) {
        self.grants = grants
    }

    /// The recordings folder, read-only.
    public func source(_ config: AppConfig) -> FolderAvailability {
        resolve(grants.current.source, expected: config.sourcePath, readOnly: true, writable: false) { refreshed in
            try? self.grants.update { $0.source?.bookmark = refreshed }
        }
    }

    /// The transcripts folder. If it is gone (Google Drive quit or signed out, a disk unplugged,
    /// the folder deleted), results wait: transcripts are never written anywhere else.
    public func destination(_ config: AppConfig) -> FolderAvailability {
        resolve(grants.current.destination, expected: config.destinationPath, readOnly: false, writable: true) { refreshed in
            try? self.grants.update { $0.destination?.bookmark = refreshed }
        }
    }

    private func resolve(_ grant: FolderGrants.Grant?, expected: String?, readOnly: Bool, writable: Bool, save: (Data) -> Void) -> FolderAvailability {
        guard let expected else { return .notGranted("not-configured") }
        guard let grant else { return .notGranted("no-grant") }
        guard Self.samePath(grant.path, expected) else { return .notGranted("grant-for-another-folder") }
        lock.lock()
        let cached = cache[grant.bookmark]
        lock.unlock()
        let url: URL
        if let cached {
            url = cached
        } else {
            switch Bookmarks.resolve(grant.bookmark, readOnly: readOnly) {
            case .unresolvable(let reason):
                if !PathProbe.exists(URL(fileURLWithPath: grant.path)) { return .notGranted("missing") }
                return .notGranted("grant-invalid:\(reason)")
            case .resolved(let folder, let refreshed):
                url = folder.url
                if let refreshed { save(refreshed) }
                lock.lock()
                cache[refreshed ?? grant.bookmark] = url
                lock.unlock()
            }
        }
        let folder = SecurityScopedFolder(url: url)
        let status = (try? folder.withAccess { dir -> PathStatus in
            let status = PathProbe.directoryStatus(dir)
            if status == .accessible, writable, !PathProbe.isWritableDirectory(dir) { return .denied }
            return status
        }) ?? .denied
        switch status {
        case .accessible: return .available(folder)
        case .denied: return .notGranted("denied")
        case .missing, .notDirectory: return .notGranted("missing")
        }
    }

    public static func samePath(_ a: String, _ b: String) -> Bool {
        func normalize(_ p: String) -> String {
            URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return normalize(a) == normalize(b)
    }
}
