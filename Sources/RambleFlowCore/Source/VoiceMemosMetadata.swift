import Foundation
import SQLite3

public struct RecordingMetadata: Sendable, Equatable {
    public var uniqueID: String?
    /// Absolute recording start.
    public var recordedAt: Date?
    public var duration: Double?
    public var title: String?
    /// In Voice Memos' Recently Deleted (or otherwise marked for eviction).
    public var deleted: Bool

    public init(uniqueID: String? = nil, recordedAt: Date? = nil, duration: Double? = nil, title: String? = nil, deleted: Bool = false) {
        self.uniqueID = uniqueID
        self.recordedAt = recordedAt
        self.duration = duration
        self.title = title
        self.deleted = deleted
    }
}

public enum MetadataSnapshot: Sendable, Equatable {
    /// Keyed by file stem.
    case available([String: RecordingMetadata])
    case unavailable(reason: String)

    public func lookup(_ stem: String) -> RecordingMetadata? {
        if case .available(let map) = self { return map[stem] }
        return nil
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Best-effort, read-only access to Voice Memos' own library (a Core Data SQLite store).
///
/// The store is opened read-only (`mode=ro`, never created, never written) and read inside one read
/// transaction, which SQLite guarantees is a consistent snapshot even while Voice Memos writes to
/// its WAL. The schema is private to Apple and changes between releases: columns are discovered
/// at runtime, and anything missing degrades to "unavailable" so callers fall back to file names.
public enum VoiceMemosMetadata {
    public static let databaseName = "CloudRecordings.db"
    static let coreDataEpoch = Date(timeIntervalSinceReferenceDate: 0)

    public static func databaseURL(inRecordingsFolder folder: URL) -> URL? {
        let candidates = [folder.appendingPathComponent(databaseName), folder.deletingLastPathComponent().appendingPathComponent(databaseName)]
        return candidates.first { PathProbe.exists($0) }
    }

    /// `scratch` is where a private copy may be made (it holds titles, so it must be a private
    /// folder; the copy is deleted straight after reading).
    public static func load(recordingsFolder folder: URL, scratch: URL? = nil) -> MetadataSnapshot {
        guard let url = databaseURL(inRecordingsFolder: folder) else {
            return .unavailable(reason: "no-database")
        }
        return load(databaseURL: url, scratch: scratch)
    }

    public static func load(databaseURL url: URL, scratch: URL? = nil) -> MetadataSnapshot {
        let direct = readInPlace(url)
        if direct.isAvailable { return direct }
        if case .unavailable(let reason) = direct, reason.hasPrefix("schema") { return direct }
        // A reader that cannot update the WAL index (-shm) of a live WAL database cannot read it in
        // place. Fall back to a private copy of the database and its WAL, taken only when both
        // files were unchanged across the copy (retried a few times), so the copy is a state the
        // database was actually in. The original is never opened for writing.
        return readCopy(url, scratch: scratch ?? FileManager.default.temporaryDirectory) ?? direct
    }

    static func readInPlace(_ url: URL) -> MetadataSnapshot {
        let uri = "file:" + (url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path) + "?mode=ro"
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX)
        } catch {
            return .unavailable(reason: "open-failed")
        }
        do {
            try connection.execute("BEGIN")
            defer { try? connection.execute("COMMIT") }
            return try read(connection)
        } catch {
            return .unavailable(reason: "read-failed")
        }
    }

    private static func fileState(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "absent" }
        return "\(values.fileSize ?? -1)@\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    static func readCopy(_ url: URL, scratch: URL) -> MetadataSnapshot? {
        let fm = FileManager.default
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let directory = scratch.appendingPathComponent("vm-metadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        for _ in 0..<3 {
            try? fm.removeItem(at: directory)
            guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
            let before = (fileState(url), fileState(wal))
            let copy = directory.appendingPathComponent(databaseName)
            guard (try? fm.copyItem(at: url, to: copy)) != nil else { return nil }
            if before.1 != "absent" { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
            guard (fileState(url), fileState(wal)) == before else { Thread.sleep(forTimeInterval: 0.2); continue }
            guard let connection = try? SQLiteConnection(path: copy.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX) else { return nil }
            do {
                try connection.execute("BEGIN")
                defer { try? connection.execute("COMMIT") }
                return try read(connection)
            } catch {
                return nil
            }
        }
        return nil
    }

    private static func read(_ db: SQLiteConnection) throws -> MetadataSnapshot {
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.text }
        guard tables.contains("ZCLOUDRECORDING") else { return .unavailable(reason: "schema-no-table") }
        let columns = Set(try db.query("PRAGMA table_info(ZCLOUDRECORDING)").compactMap { $0["name"]?.text })
        guard columns.contains("ZPATH") else { return .unavailable(reason: "schema-no-path") }

        let wanted = ["ZPATH", "ZUNIQUEID", "ZDATE", "ZDURATION", "ZENCRYPTEDTITLE", "ZCUSTOMLABEL", "ZEVICTIONDATE"]
        let selected = wanted.filter(columns.contains)
        let rows = try db.query("SELECT \(selected.joined(separator: ",")) FROM ZCLOUDRECORDING")
        var map: [String: RecordingMetadata] = [:]
        for row in rows {
            guard let path = row["ZPATH"]?.text, !path.isEmpty else { continue }
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var meta = RecordingMetadata()
            meta.uniqueID = row["ZUNIQUEID"]?.text
            if let seconds = row["ZDATE"]?.double, seconds > 0 {
                meta.recordedAt = Date(timeIntervalSinceReferenceDate: seconds)
            }
            meta.duration = row["ZDURATION"]?.double
            meta.title = title(encrypted: row["ZENCRYPTEDTITLE"]?.text, label: row["ZCUSTOMLABEL"]?.text)
            if let eviction = row["ZEVICTIONDATE"]?.double, eviction > 0 { meta.deleted = true }
            map[stem] = meta
        }
        return .available(map)
    }

    /// ZENCRYPTEDTITLE holds the visible title (plain text despite the name). ZCUSTOMLABEL can hold a
    /// machine timestamp for auto-named recordings; anything timestamp-shaped is not a title.
    static func title(encrypted: String?, label: String?) -> String? {
        for candidate in [encrypted, label] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if value.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil { continue }
            if value.range(of: #"^\d{8}[ _-]\d{6}"#, options: .regularExpression) != nil { continue }
            return value
        }
        return nil
    }
}
