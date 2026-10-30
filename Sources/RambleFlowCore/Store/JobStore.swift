import Foundation
import SQLite3

/// One recording known to Ramble Flow and its durable pipeline state.
public struct RecordingRecord: Sendable, Equatable {
    public var id: Int64 = 0
    /// File name without extension. Voice Memos names files "<date> <time>-<hash>", and a title
    /// change in Voice Memos does not rename the file, so this is the identity on disk.
    public var stem: String
    public var fileName: String
    /// Short non-reversible reference used in file names and logs.
    public var reference: String
    public var metadataID: String?
    public var title: String?
    public var recordedAt: Date?
    public var dateConfidence: DateConfidence = .unknown
    public var duration: Double?
    public var state: JobState = .discovered
    /// Machine reason code for the current state (never private content).
    public var reason: String?

    // Discovery observations
    public var observedSize: Int64 = 0
    public var observedMtime: Double = 0
    public var observeCount: Int = 0
    public var observedSince: Date
    public var firstSeenAt: Date

    // Current generation (content version) of the audio
    public var contentHash: String?
    public var generation: Int = 0
    public var snapshotSize: Int64?
    public var snapshotMtime: Double?
    public var snapshotExtension: String?

    // Provider snapshot taken when transcription of this generation starts
    public var provider: ProviderID?
    public var model: String?
    public var language: String?

    public var attempts: Int = 0
    public var uncertainAttempts: Int = 0
    public var nextAttemptAt: Date?
    public var lastError: String?

    public var transcript: String?
    public var noSpeech: Bool = false
    public var transcribedAt: Date?

    // Export
    public var reservedName: String?
    public var exportedName: String?
    public var exportedHash: String?
    public var exportedAt: Date?
    public var exportAttempts: Int = 0
    /// Lowered after a provider answered 413 for this recording.
    public var maxChunkBytes: Int?
    /// The snapshot's audio is AAC, so a short recording can be sent without re-encoding.
    public var sourceIsAAC: Bool = false

    public var updatedAt: Date

    public init(stem: String, fileName: String, now: Date) {
        self.stem = stem
        self.fileName = fileName
        self.reference = Hashing.shortReference(for: stem)
        self.observedSince = now
        self.firstSeenAt = now
        self.updatedAt = now
    }
}

public struct ChunkRecord: Sendable, Equatable {
    public var jobID: Int64
    public var generation: Int
    public var index: Int
    public var start: Double
    public var end: Double
    public var status: ChunkStatus
    public var text: String?
    public var attempts: Int

    public init(jobID: Int64, generation: Int, index: Int, start: Double, end: Double, status: ChunkStatus = .pending, text: String? = nil, attempts: Int = 0) {
        self.jobID = jobID
        self.generation = generation
        self.index = index
        self.start = start
        self.end = end
        self.status = status
        self.text = text
        self.attempts = attempts
    }
}

public struct ActivationInfo: Sendable, Equatable {
    public var cutoff: Date
    public var activatedAt: Date
}

/// Durable job state in SQLite (WAL, synchronous=FULL). Every pipeline step commits before the next
/// one starts, so a crash never loses a completed chunk or a finished transcript.
public final class JobStore: @unchecked Sendable {
    public static let schemaVersion = 2
    private let db: SQLiteConnection
    private let lock = NSRecursiveLock()

    public init(url: URL) throws {
        db = try SQLiteConnection(path: url.path)
        try db.execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    // MARK: Migrations

    /// Ordered migrations; index + 1 is the schema version reached after running it.
    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS baseline (stem TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS recordings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stem TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            reference TEXT NOT NULL,
            metadata_id TEXT,
            title TEXT,
            recorded_at REAL,
            date_confidence TEXT NOT NULL,
            duration REAL,
            state TEXT NOT NULL,
            reason TEXT,
            observed_size INTEGER NOT NULL,
            observed_mtime REAL NOT NULL,
            observe_count INTEGER NOT NULL,
            observed_since REAL NOT NULL,
            first_seen_at REAL NOT NULL,
            content_hash TEXT,
            generation INTEGER NOT NULL DEFAULT 0,
            snapshot_size INTEGER,
            snapshot_mtime REAL,
            snapshot_ext TEXT,
            provider TEXT,
            model TEXT,
            language TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            uncertain_attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at REAL,
            last_error TEXT,
            transcript TEXT,
            no_speech INTEGER NOT NULL DEFAULT 0,
            transcribed_at REAL,
            reserved_name TEXT,
            exported_name TEXT,
            exported_hash TEXT,
            exported_at REAL,
            export_attempts INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            job_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
            generation INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            status TEXT NOT NULL,
            text TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (job_id, generation, idx)
        );
        """,
        // v2: per-recording upload cap after a 413, and a state index for the worker's queries.
        """
        ALTER TABLE recordings ADD COLUMN max_chunk_bytes INTEGER;
        ALTER TABLE recordings ADD COLUMN source_is_aac INTEGER NOT NULL DEFAULT 0;
        CREATE INDEX IF NOT EXISTS recordings_state ON recordings(state);
        """,
    ]

    private func migrate() throws {
        try locked {
            let current = Int(try db.query("PRAGMA user_version").first?["user_version"]?.int ?? 0)
            guard current < Self.migrations.count else { return }
            for version in current..<Self.migrations.count {
                try db.transaction {
                    try db.execute(Self.migrations[version])
                    try db.execute("PRAGMA user_version = \(version + 1)")
                }
            }
        }
    }

    public func userVersion() throws -> Int {
        try locked { Int(try db.query("PRAGMA user_version").first?["user_version"]?.int ?? 0) }
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Activation (new-recordings cutoff)

    public func activation() throws -> ActivationInfo? {
        try locked {
            let rows = try db.query("SELECT key, value FROM meta WHERE key IN ('cutoff','activated_at')")
            var values: [String: Double] = [:]
            for row in rows {
                if let key = row["key"]?.text, let value = row["value"]?.double { values[key] = value }
            }
            guard let cutoff = values["cutoff"], let activated = values["activated_at"] else { return nil }
            return ActivationInfo(cutoff: Date(timeIntervalSince1970: cutoff), activatedAt: Date(timeIntervalSince1970: activated))
        }
    }

    /// Sets the cutoff and the baseline of recordings already present. Runs once: an existing cutoff is
    /// never moved by updates, permission repair or restarts. Returns the effective activation.
    @discardableResult
    public func activate(cutoff: Date, baselineStems: [String], now: Date) throws -> ActivationInfo {
        try locked {
            if let existing = try activation() { return existing }
            try db.transaction {
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('cutoff', ?)", [.double(cutoff.timeIntervalSince1970)])
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('activated_at', ?)", [.double(now.timeIntervalSince1970)])
                for stem in baselineStems {
                    try db.run("INSERT OR IGNORE INTO baseline(stem) VALUES (?)", [.text(stem)])
                }
            }
            return ActivationInfo(cutoff: cutoff, activatedAt: now)
        }
    }

    /// Adds recordings to the baseline (never removes any). Used when the recordings folder changes.
    public func addToBaseline(_ stems: [String]) throws {
        try locked {
            try db.transaction {
                for stem in stems {
                    try db.run("INSERT OR IGNORE INTO baseline(stem) VALUES (?)", [.text(stem)])
                }
            }
        }
    }

    public func isInBaseline(_ stem: String) throws -> Bool {
        try locked { !(try db.query("SELECT 1 FROM baseline WHERE stem = ?", [.text(stem)]).isEmpty) }
    }

    public func baselineCount() throws -> Int {
        try locked { Int(try db.query("SELECT COUNT(*) AS n FROM baseline").first?["n"]?.int ?? 0) }
    }

    public func meta(_ key: String) throws -> String? {
        try locked { try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.text }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try locked {
            if let value {
                try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(key), .text(value)])
            } else {
                try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
            }
        }
    }

    // MARK: Recordings

    public func recording(stem: String) throws -> RecordingRecord? {
        try locked { try db.query("SELECT * FROM recordings WHERE stem = ?", [.text(stem)]).first.map(Self.decode) }
    }

    public func recording(id: Int64) throws -> RecordingRecord? {
        try locked { try db.query("SELECT * FROM recordings WHERE id = ?", [.int(id)]).first.map(Self.decode) }
    }

    public func recordings(in states: [JobState]? = nil) throws -> [RecordingRecord] {
        try locked {
            if let states {
                guard !states.isEmpty else { return [] }
                let marks = states.map { _ in "?" }.joined(separator: ",")
                return try db.query("SELECT * FROM recordings WHERE state IN (\(marks)) ORDER BY id", states.map { .text($0.rawValue) }).map(Self.decode)
            }
            return try db.query("SELECT * FROM recordings ORDER BY id").map(Self.decode)
        }
    }

    public func recording(withContentHash hash: String, excluding id: Int64) throws -> RecordingRecord? {
        try locked {
            try db.query("SELECT * FROM recordings WHERE content_hash = ? AND id != ? ORDER BY id LIMIT 1", [.text(hash), .int(id)]).first.map(Self.decode)
        }
    }

    public func stateCounts() throws -> [JobState: Int] {
        try locked {
            var counts: [JobState: Int] = [:]
            for row in try db.query("SELECT state, COUNT(*) AS n FROM recordings GROUP BY state") {
                if let raw = row["state"]?.text, let state = JobState(rawValue: raw) {
                    counts[state] = Int(row["n"]?.int ?? 0)
                }
            }
            return counts
        }
    }

    public func lastExported() throws -> RecordingRecord? {
        try locked {
            try db.query("SELECT * FROM recordings WHERE state = 'exported' ORDER BY exported_at DESC LIMIT 1").first.map(Self.decode)
        }
    }

    /// Inserts (id == 0) or replaces the whole row. Returns the record with its id.
    @discardableResult
    public func save(_ record: RecordingRecord) throws -> RecordingRecord {
        try locked {
            var record = record
            let values = Self.encode(record)
            if record.id == 0 {
                let columns = values.map(\.0).joined(separator: ",")
                let marks = values.map { _ in "?" }.joined(separator: ",")
                record.id = try db.run("INSERT INTO recordings(\(columns)) VALUES (\(marks))", values.map(\.1))
            } else {
                let assignments = values.map { "\($0.0) = ?" }.joined(separator: ",")
                try db.run("UPDATE recordings SET \(assignments) WHERE id = ?", values.map(\.1) + [.int(record.id)])
            }
            return record
        }
    }

    // MARK: Chunks

    public func chunks(jobID: Int64, generation: Int) throws -> [ChunkRecord] {
        try locked {
            try db.query("SELECT * FROM chunks WHERE job_id = ? AND generation = ? ORDER BY idx", [.int(jobID), .int(Int64(generation))]).map { row in
                ChunkRecord(
                    jobID: row["job_id"]?.int ?? 0,
                    generation: Int(row["generation"]?.int ?? 0),
                    index: Int(row["idx"]?.int ?? 0),
                    start: row["start"]?.double ?? 0,
                    end: row["end"]?.double ?? 0,
                    status: ChunkStatus(rawValue: row["status"]?.text ?? "") ?? .pending,
                    text: row["text"]?.text,
                    attempts: Int(row["attempts"]?.int ?? 0))
            }
        }
    }

    /// Replaces the chunk plan of a generation. Done chunks are only ever dropped together with
    /// their whole generation (or by an explicit re-plan after a 413 of a pending chunk).
    public func replaceChunks(jobID: Int64, generation: Int, with chunks: [ChunkRecord]) throws {
        try locked {
            try db.transaction {
                try db.run("DELETE FROM chunks WHERE job_id = ? AND generation = ?", [.int(jobID), .int(Int64(generation))])
                for chunk in chunks {
                    try insert(chunk)
                }
            }
        }
    }

    public func updateChunk(_ chunk: ChunkRecord) throws {
        try locked {
            try db.run(
                "UPDATE chunks SET status = ?, text = ?, attempts = ?, start = ?, end = ? WHERE job_id = ? AND generation = ? AND idx = ?",
                [.text(chunk.status.rawValue), chunk.text.map(SQLValue.text) ?? .null, .int(Int64(chunk.attempts)),
                 .double(chunk.start), .double(chunk.end), .int(chunk.jobID), .int(Int64(chunk.generation)), .int(Int64(chunk.index))])
        }
    }

    public func deleteChunks(jobID: Int64) throws {
        try locked { try db.run("DELETE FROM chunks WHERE job_id = ?", [.int(jobID)]) }
    }

    private func insert(_ chunk: ChunkRecord) throws {
        try db.run(
            "INSERT INTO chunks(job_id, generation, idx, start, end, status, text, attempts) VALUES (?,?,?,?,?,?,?,?)",
            [.int(chunk.jobID), .int(Int64(chunk.generation)), .int(Int64(chunk.index)), .double(chunk.start), .double(chunk.end),
             .text(chunk.status.rawValue), chunk.text.map(SQLValue.text) ?? .null, .int(Int64(chunk.attempts))])
    }

    // MARK: Retention

    /// Drops transcript text cached for exported recordings older than `olderThan`. The user's exported
    /// files are never touched; pending or failed exports keep their text.
    @discardableResult
    public func purgeExportedTranscripts(olderThan cutoff: Date) throws -> Int {
        try locked {
            let rows = try db.query("SELECT id FROM recordings WHERE state = 'exported' AND transcript IS NOT NULL AND exported_at < ?", [.double(cutoff.timeIntervalSince1970)])
            for row in rows {
                if let id = row["id"]?.int {
                    try db.run("UPDATE recordings SET transcript = NULL WHERE id = ?", [.int(id)])
                    try db.run("DELETE FROM chunks WHERE job_id = ?", [.int(id)])
                }
            }
            return rows.count
        }
    }

    // MARK: Row mapping

    private static func date(_ value: SQLValue?) -> Date? {
        value?.double.map { Date(timeIntervalSince1970: $0) }
    }

    private static func dateValue(_ date: Date?) -> SQLValue {
        date.map { .double($0.timeIntervalSince1970) } ?? .null
    }

    private static func optText(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }

    static func decode(_ row: [String: SQLValue]) -> RecordingRecord {
        let now = Date()
        var r = RecordingRecord(stem: row["stem"]?.text ?? "", fileName: row["file_name"]?.text ?? "", now: now)
        r.id = row["id"]?.int ?? 0
        r.reference = row["reference"]?.text ?? r.reference
        r.metadataID = row["metadata_id"]?.text
        r.title = row["title"]?.text
        r.recordedAt = date(row["recorded_at"])
        r.dateConfidence = DateConfidence(rawValue: row["date_confidence"]?.text ?? "") ?? .unknown
        r.duration = row["duration"]?.double
        r.state = JobState(rawValue: row["state"]?.text ?? "") ?? .discovered
        r.reason = row["reason"]?.text
        r.observedSize = row["observed_size"]?.int ?? 0
        r.observedMtime = row["observed_mtime"]?.double ?? 0
        r.observeCount = Int(row["observe_count"]?.int ?? 0)
        r.observedSince = date(row["observed_since"]) ?? now
        r.firstSeenAt = date(row["first_seen_at"]) ?? now
        r.contentHash = row["content_hash"]?.text
        r.generation = Int(row["generation"]?.int ?? 0)
        r.snapshotSize = row["snapshot_size"]?.int
        r.snapshotMtime = row["snapshot_mtime"]?.double
        r.snapshotExtension = row["snapshot_ext"]?.text
        r.provider = row["provider"]?.text.flatMap(ProviderID.init(rawValue:))
        r.model = row["model"]?.text
        r.language = row["language"]?.text
        r.attempts = Int(row["attempts"]?.int ?? 0)
        r.uncertainAttempts = Int(row["uncertain_attempts"]?.int ?? 0)
        r.nextAttemptAt = date(row["next_attempt_at"])
        r.lastError = row["last_error"]?.text
        r.transcript = row["transcript"]?.text
        r.noSpeech = (row["no_speech"]?.int ?? 0) != 0
        r.transcribedAt = date(row["transcribed_at"])
        r.reservedName = row["reserved_name"]?.text
        r.exportedName = row["exported_name"]?.text
        r.exportedHash = row["exported_hash"]?.text
        r.exportedAt = date(row["exported_at"])
        r.exportAttempts = Int(row["export_attempts"]?.int ?? 0)
        r.maxChunkBytes = row["max_chunk_bytes"]?.int.map(Int.init)
        r.sourceIsAAC = (row["source_is_aac"]?.int ?? 0) != 0
        r.updatedAt = date(row["updated_at"]) ?? now
        return r
    }

    static func encode(_ r: RecordingRecord) -> [(String, SQLValue)] {
        [
            ("stem", .text(r.stem)),
            ("file_name", .text(r.fileName)),
            ("reference", .text(r.reference)),
            ("metadata_id", optText(r.metadataID)),
            ("title", optText(r.title)),
            ("recorded_at", dateValue(r.recordedAt)),
            ("date_confidence", .text(r.dateConfidence.rawValue)),
            ("duration", r.duration.map(SQLValue.double) ?? .null),
            ("state", .text(r.state.rawValue)),
            ("reason", optText(r.reason)),
            ("observed_size", .int(r.observedSize)),
            ("observed_mtime", .double(r.observedMtime)),
            ("observe_count", .int(Int64(r.observeCount))),
            ("observed_since", .double(r.observedSince.timeIntervalSince1970)),
            ("first_seen_at", .double(r.firstSeenAt.timeIntervalSince1970)),
            ("content_hash", optText(r.contentHash)),
            ("generation", .int(Int64(r.generation))),
            ("snapshot_size", r.snapshotSize.map(SQLValue.int) ?? .null),
            ("snapshot_mtime", r.snapshotMtime.map(SQLValue.double) ?? .null),
            ("snapshot_ext", optText(r.snapshotExtension)),
            ("provider", optText(r.provider?.rawValue)),
            ("model", optText(r.model)),
            ("language", optText(r.language)),
            ("attempts", .int(Int64(r.attempts))),
            ("uncertain_attempts", .int(Int64(r.uncertainAttempts))),
            ("next_attempt_at", dateValue(r.nextAttemptAt)),
            ("last_error", optText(r.lastError)),
            ("transcript", optText(r.transcript)),
            ("no_speech", .int(r.noSpeech ? 1 : 0)),
            ("transcribed_at", dateValue(r.transcribedAt)),
            ("reserved_name", optText(r.reservedName)),
            ("exported_name", optText(r.exportedName)),
            ("exported_hash", optText(r.exportedHash)),
            ("exported_at", dateValue(r.exportedAt)),
            ("export_attempts", .int(Int64(r.exportAttempts))),
            ("max_chunk_bytes", r.maxChunkBytes.map { .int(Int64($0)) } ?? .null),
            ("source_is_aac", .int(r.sourceIsAAC ? 1 : 0)),
            ("updated_at", .double(r.updatedAt.timeIntervalSince1970)),
        ]
    }
}
