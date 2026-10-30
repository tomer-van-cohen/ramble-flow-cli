import Foundation

/// Reconciles one listing of the source folder with the job store.
///
/// The folder listing is the source of truth (polled about every 10 seconds and on launch/wake);
/// file system events may only make it faster. Stability is judged by the same size and
/// modification time across consecutive scans spanning a minimum window: a heuristic, not proof
/// that a long sync finished, which is why the content is fingerprinted again before export.
public struct RecordingDiscovery {
    public var store: JobStore
    public var policy: EligibilityPolicy
    public var stabilityWindow: TimeInterval
    public var missingGrace: TimeInterval

    public init(store: JobStore, policy: EligibilityPolicy, stabilityWindow: TimeInterval = 15, missingGrace: TimeInterval = 60) {
        self.store = store
        self.policy = policy
        self.stabilityWindow = stabilityWindow
        self.missingGrace = missingGrace
    }

    public struct Summary: Equatable, Sendable {
        public var newlyEligible = 0
        public var excluded = 0
        public var undetermined = 0
        public var becameStable = 0
        public var sourceChanged = 0
        public var canceled = 0
    }

    @discardableResult
    public func reconcile(files: [SourceFile], metadata: MetadataSnapshot, now: Date) throws -> Summary {
        var summary = Summary()
        var seen = Set<String>()
        for file in files {
            seen.insert(file.stem)
            let meta = metadata.lookup(file.stem)
            if var record = try store.recording(stem: file.stem) {
                try update(&record, file: file, meta: meta, now: now, summary: &summary)
            } else {
                try insert(file: file, meta: meta, now: now, summary: &summary)
            }
        }
        try handleMissing(seen: seen, metadata: metadata, now: now, summary: &summary)
        return summary
    }

    private func evidence(for file: SourceFile, meta: RecordingMetadata?, inBaseline: Bool) -> EligibilityPolicy.Evidence {
        EligibilityPolicy.Evidence(
            inBaseline: inBaseline,
            metadataDate: meta?.recordedAt,
            fileNameWallClock: FileNameDate.parse(file.fileName),
            modified: file.modified,
            deletedInVoiceMemos: meta?.deleted ?? false)
    }

    private func applyMetadata(_ record: inout RecordingRecord, file: SourceFile, meta: RecordingMetadata?) {
        if let meta {
            record.metadataID = meta.uniqueID ?? record.metadataID
            if let title = meta.title { record.title = title }
            if let date = meta.recordedAt {
                record.recordedAt = date
                record.dateConfidence = .metadata
            }
            if let duration = meta.duration, duration > 0 { record.duration = duration }
        }
        if record.dateConfidence != .metadata, let wall = FileNameDate.parse(file.fileName) {
            record.recordedAt = FileNameDate.instant(wall, in: .current)
            record.dateConfidence = .fileName
        }
    }

    private func insert(file: SourceFile, meta: RecordingMetadata?, now: Date, summary: inout Summary) throws {
        var record = RecordingRecord(stem: file.stem, fileName: file.fileName, now: now)
        record.observedSize = file.size
        record.observedMtime = file.modified.timeIntervalSince1970
        record.observeCount = 1
        applyMetadata(&record, file: file, meta: meta)
        let inBaseline = try store.isInBaseline(file.stem)
        switch policy.decide(evidence(for: file, meta: meta, inBaseline: inBaseline)) {
        case .eligible:
            record.state = .waitingForSync
            record.reason = file.size == 0 ? "placeholder" : nil
            summary.newlyEligible += 1
        case .excluded(let reason):
            record.state = .excluded
            record.reason = reason
            summary.excluded += 1
        case .undetermined(let reason):
            record.state = .needsDecision
            record.reason = reason
            summary.undetermined += 1
        }
        try store.save(record)
    }

    private func update(_ record: inout RecordingRecord, file: SourceFile, meta: RecordingMetadata?, now: Date, summary: inout Summary) throws {
        let original = record
        if record.state == .excluded || record.state == .exported || record.state == .canceled {
            // v1 does not re-transcribe after success, and excluded/canceled recordings stay that way.
            return
        }
        applyMetadata(&record, file: file, meta: meta)

        // Observation bookkeeping (size + mtime across scans).
        let mtime = file.modified.timeIntervalSince1970
        if file.size == record.observedSize && mtime == record.observedMtime && record.reason != "source-missing" {
            record.observeCount += 1
        } else {
            record.observedSize = file.size
            record.observedMtime = mtime
            record.observeCount = 1
            record.observedSince = now
            if record.reason == "source-missing" { record.reason = nil }
        }

        if meta?.deleted == true {
            record.state = .canceled
            record.reason = "deleted-in-voice-memos"
            summary.canceled += 1
        } else if record.state == .needsDecision, record.reason != "awaiting-user" {
            switch policy.decide(evidence(for: file, meta: meta, inBaseline: try store.isInBaseline(file.stem))) {
            case .eligible:
                record.state = .waitingForSync
                record.reason = nil
                summary.newlyEligible += 1
            case .excluded(let reason):
                record.state = .excluded
                record.reason = reason
                summary.excluded += 1
            case .undetermined:
                break
            }
        }

        if record.state == .waitingForSync {
            if file.size == 0 {
                record.reason = "placeholder"
            } else if record.observeCount >= 2 && now.timeIntervalSince(record.observedSince) >= stabilityWindow {
                record.state = .preparing
                record.reason = nil
                summary.becameStable += 1
            } else {
                record.reason = nil
            }
        } else if record.state.isActive, record.state != .sourceChanged, let snapSize = record.snapshotSize, let snapMtime = record.snapshotMtime,
                  snapSize != file.size || snapMtime != mtime {
            // The file differs from the local snapshot being transcribed. The worker re-fingerprints it
            // and either resumes (same content) or starts a new generation; texts from two audio
            // versions are never assembled together.
            record.state = .sourceChanged
            summary.sourceChanged += 1
        }

        if record != original {
            record.updatedAt = now
            try store.save(record)
        }
    }

    private func handleMissing(seen: Set<String>, metadata: MetadataSnapshot, now: Date, summary: inout Summary) throws {
        let watched: [JobState] = [.waitingForSync, .needsDecision, .preparing, .queued, .transcribing, .readyToExport,
                                   .retryScheduled, .needsCredentials, .needsFolderAccess, .needsAttention,
                                   .providerOutcomeUnknown, .unsupportedAudio, .sourceChanged]
        for var record in try store.recordings(in: watched) where !seen.contains(record.stem) {
            if record.reason != "source-missing" {
                record.reason = "source-missing"
                record.observedSince = now
                record.updatedAt = now
                try store.save(record)
            } else if now.timeIntervalSince(record.observedSince) >= missingGrace {
                record.state = .canceled
                record.reason = "source-deleted"
                record.updatedAt = now
                try store.save(record)
                summary.canceled += 1
            }
        }
    }
}
