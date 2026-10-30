import Foundation

public enum WorkerError: Error, Equatable {
    /// The recordings folder cannot be listed ("denied": not granted; "missing").
    case sourceUnavailable(String)
}

public struct WorkerDependencies: Sendable {
    public var store: JobStore
    public var paths: AppPaths
    public var config: ConfigStore
    public var credentials: CredentialStore
    public var audio: AudioPipeline
    public var makeProvider: @Sendable (ProviderID, String) -> TranscriptionProvider
    public var sourceFolder: @Sendable () -> FolderAvailability
    public var destinationFolder: @Sendable () -> FolderAvailability
    public var metadata: @Sendable (URL) -> MetadataSnapshot
    public var now: @Sendable () -> Date
    public var jitter: @Sendable () -> Double
    public var settings: WorkerSettings

    public init(store: JobStore, paths: AppPaths, config: ConfigStore, credentials: CredentialStore, audio: AudioPipeline,
                makeProvider: @escaping @Sendable (ProviderID, String) -> TranscriptionProvider,
                sourceFolder: @escaping @Sendable () -> FolderAvailability,
                destinationFolder: @escaping @Sendable () -> FolderAvailability,
                metadata: @escaping @Sendable (URL) -> MetadataSnapshot = { VoiceMemosMetadata.load(recordingsFolder: $0) },
                now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) },
                settings: WorkerSettings = WorkerSettings()) {
        self.store = store
        self.paths = paths
        self.config = config
        self.credentials = credentials
        self.audio = audio
        self.makeProvider = makeProvider
        self.sourceFolder = sourceFolder
        self.destinationFolder = destinationFolder
        self.metadata = metadata
        self.now = now
        self.jitter = jitter
        self.settings = settings
    }
}

/// The single background worker. One scan and one recording at a time; every step is committed to
/// the job store before the next begins, so it can be stopped at any point and resume later.
public actor TranscriptionWorker {
    private let deps: WorkerDependencies
    private var ticking = false
    private var lastPurge: Date?
    private var onStatus: (@Sendable (WorkerStatus) -> Void)?
    public private(set) var status = WorkerStatus(phase: .notActivated)
    /// Energy profiles computed this session, per job/generation (not persisted; cheap to redo).
    private var energyCache: [String: EnergyProfile] = [:]

    public init(dependencies: WorkerDependencies) {
        self.deps = dependencies
    }

    public func setStatusHandler(_ handler: (@Sendable (WorkerStatus) -> Void)?) {
        onStatus = handler
    }

    // MARK: - Activation

    /// Establishes the new-recordings cutoff and the baseline of recordings already present.
    /// Idempotent: once set, the cutoff never moves.
    @discardableResult
    public func activate() throws -> ActivationInfo {
        if let existing = try deps.store.activation() { return existing }
        let availability = deps.sourceFolder()
        guard case .available(let source) = availability else {
            if case .notGranted(let reason) = availability { throw WorkerError.sourceUnavailable(reason) }
            throw WorkerError.sourceUnavailable("unknown")
        }
        let now = deps.now()
        let stems = try source.withAccess { try VoiceMemosSource.listRecordings(in: $0).map(\.stem) }
        let info = try deps.store.activate(cutoff: now, baselineStems: stems, now: now)
        try deps.store.setMeta("baseline-source", source.url.standardizedFileURL.path)
        Log.shared.info("activated: baseline of \(stems.count) recording(s)")
        return info
    }

    /// When the recordings folder is changed after activation, the recordings already in the new
    /// folder join the baseline, so "new recordings only" holds there too. The cutoff never moves.
    private func extendBaselineIfSourceChanged(_ source: FolderAccess, files: [SourceFile]) throws {
        let path = source.url.standardizedFileURL.path
        let previous = try deps.store.meta("baseline-source")
        guard previous != path else { return }
        if previous != nil {
            let known = Set(try deps.store.recordings().map(\.stem))
            let added = files.map(\.stem).filter { !known.contains($0) }
            try deps.store.addToBaseline(added)
            Log.shared.info("recordings folder changed: \(added.count) recording(s) already there added to the baseline")
        }
        try deps.store.setMeta("baseline-source", path)
    }

    /// When the transcripts folder changes, results not yet exported go to the new folder.
    private func followDestinationChange() throws {
        let path = deps.config.current.destinationPath
        let previous = try deps.store.meta("destination-path")
        guard previous != path else { return }
        if previous != nil {
            try destinationChanged()
            Log.shared.info("transcripts folder changed: pending results will be saved in the new folder")
        }
        try deps.store.setMeta("destination-path", path)
    }

    // MARK: - Loop

    /// Runs `tick` about every `interval` seconds until the task is cancelled. `wake` lets the app
    /// trigger an immediate pass (launch, wake from sleep, settings change).
    public func run(interval: TimeInterval = 10, wake: AsyncStream<Void>? = nil) async {
        let wakeTask = Task { [weak self] in
            guard let wake else { return }
            for await _ in wake {
                await self?.tick()
            }
        }
        defer { wakeTask.cancel() }
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// One scan plus processing of every job that is due. Overlapping calls return immediately.
    @discardableResult
    public func tick() async -> WorkerStatus {
        guard !ticking else { return status }
        ticking = true
        defer { ticking = false }
        do {
            try await tickBody()
        } catch {
            Log.shared.error("worker pass failed: \(Self.describe(error))")
        }
        publish(computeStatus())
        return status
    }

    private func tickBody() async throws {
        guard let activation = try deps.store.activation() else { return }
        guard case .available(let source) = deps.sourceFolder() else { return }

        // Discovery
        do {
            let metadataReader = deps.metadata
            let (files, metadata) = try source.withAccess { url in
                (try VoiceMemosSource.listRecordings(in: url), metadataReader(url))
            }
            try extendBaselineIfSourceChanged(source, files: files)
            let discovery = RecordingDiscovery(store: deps.store, policy: EligibilityPolicy(cutoff: activation.cutoff),
                                               stabilityWindow: deps.settings.stabilityWindow, missingGrace: deps.settings.missingGrace)
            _ = try source.withAccess { _ in
                try discovery.reconcile(files: files, metadata: metadata, now: deps.now())
            }
        } catch {
            Log.shared.warn("scan failed: \(Self.describe(error))")
            sourceScanFailed = true
            return
        }
        sourceScanFailed = false

        try followDestinationChange()
        purgeIfDue()
        if deps.config.current.paused { return }

        // Process due jobs, oldest first, one at a time.
        var guardCounter = 0
        while guardCounter < 500, !Task.isCancelled {
            guardCounter += 1
            if deps.config.current.paused { break }
            guard let job = try nextDueJob() else { break }
            let progressed = try await advance(job, source: source)
            if !progressed { break }
        }
    }

    private var sourceScanFailed = false

    // MARK: - Scheduling

    private func nextDueJob() throws -> RecordingRecord? {
        let now = deps.now()
        let candidates = try deps.store.recordings(in: [.sourceChanged, .readyToExport, .transcribing, .queued, .preparing,
                                                         .retryScheduled, .needsCredentials, .needsFolderAccess, .needsAttention])
        for job in candidates {
            if job.reason == "source-missing" { continue }
            switch job.state {
            case .sourceChanged, .preparing, .queued, .transcribing:
                if let next = job.nextAttemptAt, next > now { continue }
                return job
            case .readyToExport:
                if let next = job.nextAttemptAt, next > now { continue }
                return job
            case .retryScheduled:
                if let next = job.nextAttemptAt, next > now { continue }
                return job
            case .needsCredentials:
                if try credentialUsable(for: job.provider ?? deps.config.current.provider) { return job }
            case .needsFolderAccess:
                if case .available(let folder) = deps.destinationFolder(), (try? folder.withAccess({ PathProbe.isWritableDirectory($0) })) == true {
                    return job
                }
            case .needsAttention:
                if job.reason == "quota", let next = job.nextAttemptAt, next <= now { return job }
            default:
                continue
            }
        }
        return nil
    }

    /// Where a job continues after waiting.
    private func resumeState(_ job: RecordingRecord) throws -> JobState {
        if job.transcript != nil || job.transcribedAt != nil { return .readyToExport }
        if job.contentHash == nil { return .preparing }
        if !(try deps.store.chunks(jobID: job.id, generation: job.generation)).isEmpty { return .transcribing }
        return .queued
    }

    private func credentialUsable(for provider: ProviderID) throws -> Bool {
        guard let key = try? deps.credentials.key(for: provider), !key.isEmpty else { return false }
        let rejected = try deps.store.meta("rejected-key.\(provider.rawValue)")
        return rejected != Self.keyFingerprint(key)
    }

    static func keyFingerprint(_ key: String) -> String {
        String(Hashing.sha256("ramble-flow-key:" + key).prefix(16))
    }

    // MARK: - State machine

    /// Advances one job by one or more steps. Returns false when the worker should stop this pass
    /// (waiting on time, network, provider or user).
    private func advance(_ initial: RecordingRecord, source: FolderAccess) async throws -> Bool {
        var job = initial
        switch job.state {
        case .retryScheduled, .needsCredentials, .needsFolderAccess, .needsAttention:
            job.state = try resumeState(job)
            job.nextAttemptAt = nil
            if job.reason != "source-missing" { job.reason = nil }
            job = try save(job)
        default:
            break
        }

        switch job.state {
        case .sourceChanged:
            return try await handleSourceChange(job, source: source)
        case .preparing:
            return try await prepare(job, source: source)
        case .queued:
            return try await plan(job)
        case .transcribing:
            return try await transcribe(job)
        case .readyToExport:
            return try await exportTranscript(job, source: source)
        default:
            return true
        }
    }

    @discardableResult
    private func save(_ job: RecordingRecord) throws -> RecordingRecord {
        var job = job
        job.updatedAt = deps.now()
        return try deps.store.save(job)
    }

    private func schedule(_ job: inout RecordingRecord, state: JobState = .retryScheduled, reason: String, after delay: TimeInterval?) throws {
        job.state = state
        job.reason = reason
        job.nextAttemptAt = delay.map { deps.now().addingTimeInterval($0) }
        try save(job)
        Log.shared.info("job \(job.reference): \(state.rawValue) (\(reason))")
    }

    private func backoff(attempt: Int, base: TimeInterval = 15, cap: TimeInterval? = nil) -> TimeInterval {
        let cap = cap ?? deps.settings.maxBackoff
        let raw = min(cap, base * pow(2, Double(max(0, attempt - 1))))
        return raw * deps.jitter()
    }

    private func workDirectory(_ job: RecordingRecord) -> URL {
        deps.paths.workDirectory(forJob: job.id)
    }

    private func snapshotURL(_ job: RecordingRecord) -> URL {
        workDirectory(job).appendingPathComponent("source-g\(job.generation).\(job.snapshotExtension ?? "m4a")")
    }

    // MARK: Source changes

    private func handleSourceChange(_ initial: RecordingRecord, source: FolderAccess) async throws -> Bool {
        var job = initial
        let file = source.url.appendingPathComponent(job.fileName)
        let current: (size: Int64, mtime: Double, hash: String)?
        current = try source.withAccess { _ -> (Int64, Double, String)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let hash = try Hashing.sha256(of: file)
            return (Int64(values.fileSize ?? 0), values.contentModificationDate?.timeIntervalSince1970 ?? 0, hash)
        }
        guard let current else { return true }   // missing: discovery cancels it after the grace period
        if current.hash == job.contentHash {
            // Touched but identical (e.g. metadata rewrite): keep all completed work.
            job.snapshotSize = current.size
            job.snapshotMtime = current.mtime
            job.state = try resumeState(job)
            job.reason = nil
            try save(job)
            return true
        }
        // New audio version: drop the old generation entirely, wait for the file to settle again.
        Log.shared.info("job \(job.reference): source changed, starting generation \(job.generation + 1)")
        try? FileManager.default.removeItem(at: workDirectory(job))
        try deps.store.deleteChunks(jobID: job.id)
        job.generation += 1
        job.contentHash = nil
        job.snapshotSize = nil
        job.snapshotMtime = nil
        job.snapshotExtension = nil
        job.provider = nil
        job.model = nil
        job.transcript = nil
        job.transcribedAt = nil
        job.noSpeech = false
        job.reservedName = nil
        job.attempts = 0
        job.uncertainAttempts = 0
        job.maxChunkBytes = nil
        job.state = .waitingForSync
        job.reason = "source-changed"
        job.observeCount = 1
        job.observedSize = current.size
        job.observedMtime = current.mtime
        job.observedSince = deps.now()
        try save(job)
        return true
    }

    // MARK: Prepare (snapshot + fingerprint + inspection)

    private func workBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: deps.paths.work, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func prepare(_ initial: RecordingRecord, source: FolderAccess) async throws -> Bool {
        var job = initial
        if workBytes() > deps.settings.maxWorkBytes {
            try schedule(&job, state: .preparing, reason: "work-space-full", after: 300)
            return false
        }
        let directory = workDirectory(job)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = source.url.appendingPathComponent(job.fileName)

        // Local snapshot: never read Apple's container more than needed, never modify it.
        let outcome: (ext: String, size: Int64, mtime: Double)? = try source.withAccess { _ in
            guard let before = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            guard let ext = AudioContainer.sniffExtension(of: file) else { return ("", -1, 0) }
            let target = directory.appendingPathComponent("source-g\(job.generation).\(ext)")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
            guard let after = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  after.fileSize == before.fileSize, after.contentModificationDate == before.contentModificationDate else {
                try? FileManager.default.removeItem(at: target)
                return (ext, -2, 0)
            }
            return (ext, Int64(after.fileSize ?? 0), after.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        guard let outcome else { return true }   // missing; discovery handles it
        if outcome.size == -1 {
            job.attempts += 1
            if job.attempts >= 4 {
                try schedule(&job, state: .unsupportedAudio, reason: "unrecognized-container", after: nil)
            } else {
                try schedule(&job, reason: "unrecognized-container", after: backoff(attempt: job.attempts, base: 60))
            }
            return true
        }
        if outcome.size == -2 {
            // Still being written: wait for stability again.
            job.state = .waitingForSync
            job.reason = "changed-during-snapshot"
            job.observeCount = 1
            job.observedSince = deps.now()
            try save(job)
            return true
        }

        job.snapshotExtension = outcome.ext
        job.snapshotSize = outcome.size
        job.snapshotMtime = outcome.mtime
        let snapshot = snapshotURL(job)
        let hash = try Hashing.sha256(of: snapshot)
        job.contentHash = hash

        // Same audio already handled under another file name (a rename): no second paid request.
        if let twin = try deps.store.recording(withContentHash: hash, excluding: job.id), twin.state != .canceled, twin.state != .excluded {
            try? FileManager.default.removeItem(at: directory)
            job.state = .canceled
            job.reason = "duplicate-of-\(twin.reference)"
            try save(job)
            Log.shared.info("job \(job.reference): same audio as \(twin.reference), skipped")
            return true
        }

        do {
            let info = try await deps.audio.inspect(snapshot)
            job.duration = info.duration
            job.state = .queued
            job.sourceIsAAC = info.isAAC
            job.reason = nil
            job.attempts = 0
            try save(job)
            Log.shared.info("job \(job.reference): prepared \(Int(info.duration))s")
            return true
        } catch {
            job.attempts += 1
            job.contentHash = nil
            if job.attempts >= 4 {
                try schedule(&job, state: .unsupportedAudio, reason: "unreadable-audio", after: nil)
            } else {
                // Possibly an incomplete download that happened to look stable: try again later.
                try schedule(&job, reason: "unreadable-audio", after: backoff(attempt: job.attempts, base: 60))
            }
            return true
        }
    }

    // MARK: Plan

    private func energy(for job: RecordingRecord) async -> EnergyProfile? {
        let key = "\(job.id)-\(job.generation)"
        if let cached = energyCache[key] { return cached }
        guard let profile = try? await deps.audio.energyProfile(snapshotURL(job)) else { return nil }
        if energyCache.count > 4 { energyCache.removeAll() }
        energyCache[key] = profile
        return profile
    }

    private func providerFor(_ job: RecordingRecord) -> TranscriptionProvider {
        let id = job.provider ?? deps.config.current.provider
        return deps.makeProvider(id, job.model ?? id.defaultModel)
    }

    private func limits(for provider: TranscriptionProvider, job: RecordingRecord) -> ChunkPlanner.Limits {
        let target = min(provider.capabilities.targetUploadBytes, job.maxChunkBytes ?? Int.max)
        return ChunkPlanner.Limits(maxDuration: provider.capabilities.maxChunkDuration, targetBytes: target,
                                   bytesPerSecond: AVFoundationAudioPipeline.plannedBytesPerSecond)
    }

    private func plan(_ initial: RecordingRecord) async throws -> Bool {
        var job = initial
        let config = deps.config.current
        // Newly queued recordings adopt the current provider, model and language.
        job.provider = config.provider
        job.model = config.effectiveModel
        job.language = config.languageHint
        guard let duration = job.duration, duration > 0 else {
            job.contentHash = nil
            job.state = .preparing
            try save(job)
            return true
        }
        let provider = providerFor(job)
        let profile = await energy(for: job)
        let spans = ChunkPlanner.plan(duration: duration, energy: profile, limits: limits(for: provider, job: job))
        let chunks = spans.enumerated().map { ChunkRecord(jobID: job.id, generation: job.generation, index: $0.offset, start: $0.element.start, end: $0.element.end) }
        try deps.store.replaceChunks(jobID: job.id, generation: job.generation, with: chunks)
        job.state = .transcribing
        try save(job)
        Log.shared.info("job \(job.reference): planned \(chunks.count) request(s) with \(provider.id.displayName)")
        return true
    }

    // MARK: Transcribe

    private func transcribe(_ initial: RecordingRecord) async throws -> Bool {
        var job = initial
        var chunks = try deps.store.chunks(jobID: job.id, generation: job.generation)
        if chunks.isEmpty {
            job.state = .queued
            try save(job)
            return true
        }
        let current = deps.config.current
        let started = chunks.contains { $0.status == .done }
        if !started, job.provider != current.provider || job.model != current.effectiveModel || job.language != current.languageHint {
            // Nothing transcribed yet: adopt the provider, model and language chosen since.
            job.state = .queued
            try save(job)
            return true
        }
        let providerID = job.provider ?? current.provider

        let key: String
        do {
            guard let stored = try deps.credentials.key(for: providerID), !stored.isEmpty else {
                try schedule(&job, state: .needsCredentials, reason: providerID == current.provider ? "no-key" : "provider-changed", after: nil)
                return false
            }
            if try deps.store.meta("rejected-key.\(providerID.rawValue)") == Self.keyFingerprint(stored) {
                try schedule(&job, state: .needsCredentials, reason: "key-rejected", after: nil)
                return false
            }
            key = stored
        } catch {
            try schedule(&job, reason: "credentials-unreadable", after: 60)
            return false
        }

        let provider = providerFor(job)
        let profile = await energy(for: job)
        let snapshot = snapshotURL(job)

        var index = 0
        while index < chunks.count {
            var chunk = chunks[index]
            if chunk.status == .done { index += 1; continue }
            if deps.config.current.paused { return false }

            let span = ChunkSpan(start: chunk.start, end: chunk.end)
            if let profile, profile.isSilent(span) {
                // Silence is a valid "no speech" result; nothing is uploaded for it.
                chunk.status = .done
                chunk.text = ""
                try deps.store.updateChunk(chunk)
                chunks[index] = chunk
                index += 1
                continue
            }

            let chunkFile = workDirectory(job).appendingPathComponent("chunk-g\(job.generation)-\(chunk.index).m4a")
            let passthrough = chunks.count == 1 && job.sourceIsAAC && (job.snapshotSize ?? .max) <= Int64(provider.capabilities.targetUploadBytes)
            do {
                try await deps.audio.prepareChunk(source: snapshot, span: span, passthrough: passthrough, to: chunkFile)
            } catch {
                job.attempts += 1
                if job.attempts >= 4 {
                    try schedule(&job, state: .unsupportedAudio, reason: "prepare-failed", after: nil)
                } else {
                    try schedule(&job, reason: "prepare-failed", after: backoff(attempt: job.attempts, base: 30))
                }
                return true
            }
            let size = (try? chunkFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let cap = min(provider.capabilities.maxUploadBytes, job.maxChunkBytes ?? Int.max)
            if size > cap {
                try? FileManager.default.removeItem(at: chunkFile)
                guard span.duration >= deps.settings.minimumSplitDuration * 2 else {
                    try schedule(&job, state: .unsupportedAudio, reason: "cannot-fit-upload-limit", after: nil)
                    return true
                }
                chunks = try resplit(job: job, chunks: chunks, at: index, energy: profile)
                continue
            }

            do {
                let result = try await provider.transcribe(audio: chunkFile, language: job.language, apiKey: key)
                try? FileManager.default.removeItem(at: chunkFile)
                chunk.status = .done
                chunk.text = result.text
                chunk.attempts += 1
                try deps.store.updateChunk(chunk)   // committed before the next request
                chunks[index] = chunk
                job.attempts = 0
                job.uncertainAttempts = 0
                job = try save(job)
                index += 1
            } catch let error as ProviderError {
                try? FileManager.default.removeItem(at: chunkFile)
                chunk.attempts += 1
                try deps.store.updateChunk(chunk)
                switch try handle(error, job: &job, chunks: &chunks, index: index, chunkBytes: size, energy: profile) {
                case .retryNow: continue
                case .stopPass: return false
                case .nextJob: return true
                }
            }
        }

        // All parts succeeded: assemble in order, only now.
        let texts = chunks.sorted { $0.index < $1.index }.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        job.transcript = texts.joined(separator: "\n\n")
        job.noSpeech = texts.isEmpty
        job.transcribedAt = deps.now()
        job.state = .readyToExport
        job.reason = nil
        job.attempts = 0
        try save(job)
        Log.shared.info("job \(job.reference): transcribed (\(chunks.count) part(s))")
        return true
    }

    private enum ErrorOutcome { case retryNow, stopPass, nextJob }

    private func handle(_ error: ProviderError, job: inout RecordingRecord, chunks: inout [ChunkRecord], index: Int, chunkBytes: Int, energy: EnergyProfile?) throws -> ErrorOutcome {
        let providerID = job.provider ?? deps.config.current.provider
        Log.shared.warn("job \(job.reference): \(providerID.displayName) \(error.shortCode)")
        switch error {
        case .offline:
            job.attempts += 1
            try schedule(&job, reason: "offline", after: backoff(attempt: job.attempts, base: 10, cap: deps.settings.offlineMaxBackoff))
            return .stopPass
        case .uncertain:
            job.uncertainAttempts += 1
            if job.uncertainAttempts >= deps.settings.maxUncertainAttempts {
                try schedule(&job, state: .providerOutcomeUnknown, reason: "uncertain-outcome", after: nil)
                return .nextJob
            }
            job.attempts += 1
            try schedule(&job, reason: "uncertain", after: backoff(attempt: job.attempts, base: 30))
            return .stopPass
        case .malformedResponse:
            job.uncertainAttempts += 1
            if job.uncertainAttempts >= deps.settings.maxUncertainAttempts {
                try schedule(&job, state: .providerOutcomeUnknown, reason: "malformed-response", after: nil)
                return .nextJob
            }
            job.attempts += 1
            try schedule(&job, reason: "malformed-response", after: backoff(attempt: job.attempts, base: 30))
            return .stopPass
        case .unauthorized, .forbidden:
            if let key = try? deps.credentials.key(for: providerID) {
                try deps.store.setMeta("rejected-key.\(providerID.rawValue)", Self.keyFingerprint(key))
            }
            try schedule(&job, state: .needsCredentials, reason: error.shortCode == "forbidden" ? "key-forbidden" : "key-rejected", after: nil)
            return .stopPass
        case .payloadTooLarge:
            let lowered = Int(Double(chunkBytes) * 0.6)
            job.maxChunkBytes = min(job.maxChunkBytes ?? Int.max, max(lowered, 1_000_000))
            let span = ChunkSpan(start: chunks[index].start, end: chunks[index].end)
            guard span.duration >= deps.settings.minimumSplitDuration * 2 else {
                try schedule(&job, state: .unsupportedAudio, reason: "cannot-fit-upload-limit", after: nil)
                return .nextJob
            }
            job = try save(job)
            chunks = try resplit(job: job, chunks: chunks, at: index, energy: energy)
            return .retryNow
        case .rateLimited(let retryAfter):
            job.attempts += 1
            let wait = retryAfter.map { max(1, $0) } ?? backoff(attempt: job.attempts, base: 30)
            try schedule(&job, reason: "rate-limited", after: wait)
            return .stopPass
        case .quotaExhausted:
            try schedule(&job, state: .needsAttention, reason: "quota", after: deps.settings.quotaRetry)
            return .stopPass
        case .configuration(let code):
            try schedule(&job, state: .needsAttention, reason: "configuration:\(code)", after: nil)
            return .stopPass
        case .invalidAudio(let code):
            try schedule(&job, state: .unsupportedAudio, reason: "provider-rejected-audio:\(code)", after: nil)
            return .nextJob
        case .server(let status):
            job.attempts += 1
            try schedule(&job, reason: "server-\(status)", after: backoff(attempt: job.attempts, base: 20))
            return .stopPass
        case .canceled:
            return .stopPass
        }
    }

    /// Replaces pending chunk `index` with two halves split at a quiet point. Done chunks are kept.
    private func resplit(job: RecordingRecord, chunks: [ChunkRecord], at index: Int, energy: EnergyProfile?) throws -> [ChunkRecord] {
        let span = ChunkSpan(start: chunks[index].start, end: chunks[index].end)
        let halves = ChunkPlanner.split(span, energy: energy)
        var spans: [(ChunkSpan, ChunkStatus, String?, Int)] = []
        for (i, chunk) in chunks.enumerated() {
            if i == index {
                for half in halves { spans.append((half, .pending, nil, 0)) }
            } else {
                spans.append((ChunkSpan(start: chunk.start, end: chunk.end), chunk.status, chunk.text, chunk.attempts))
            }
        }
        let rebuilt = spans.enumerated().map { offset, item in
            ChunkRecord(jobID: job.id, generation: job.generation, index: offset, start: item.0.start, end: item.0.end, status: item.1, text: item.2, attempts: item.3)
        }
        try deps.store.replaceChunks(jobID: job.id, generation: job.generation, with: rebuilt)
        Log.shared.info("job \(job.reference): split a request (now \(rebuilt.count) parts)")
        return rebuilt
    }

    // MARK: Export

    private func exportTranscript(_ initial: RecordingRecord, source: FolderAccess) async throws -> Bool {
        var job = initial
        guard let transcript = job.transcript else {
            // Inconsistent row (no text to export): transcribe this generation again.
            job.state = .queued
            try save(job)
            return true
        }

        // The transcript must belong to the audio that is in the source folder now.
        let file = source.url.appendingPathComponent(job.fileName)
        let unchanged: Bool? = try source.withAccess { _ in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let size = Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if size == job.snapshotSize && mtime == job.snapshotMtime { return true }
            return try Hashing.sha256(of: file) == job.contentHash
        }
        guard let unchanged else { return true }   // missing right now; discovery decides
        if !unchanged {
            job.state = .sourceChanged
            try save(job)
            return true
        }

        let destinationAvailability = deps.destinationFolder()
        guard case .available(let destination) = destinationAvailability else {
            if case .notGranted("missing") = destinationAvailability {
                // Drive offline or folder gone: keep the result and retry this folder later.
                // Never fall back to another location.
                job.exportAttempts += 1
                try schedule(&job, state: .readyToExport, reason: "destination-missing", after: backoff(attempt: job.exportAttempts, base: 30, cap: 600))
            } else {
                try schedule(&job, state: .needsFolderAccess, reason: "destination-not-granted", after: nil)
            }
            return false
        }

        let providerID = job.provider ?? deps.config.current.provider
        let document = TranscriptDocument(title: job.title, recordedAt: job.recordedAt, dateConfidence: job.dateConfidence, duration: job.duration,
                                          providerName: providerID.displayName, model: job.model ?? providerID.defaultModel,
                                          reference: job.reference, text: transcript, noSpeech: job.noSpeech)
        let contents = document.rendered()
        if job.reservedName == nil {
            job.reservedName = TranscriptNaming.fileName(recordedAt: job.recordedAt, title: job.title, reference: job.reference)
            job = try save(job)
        }
        let snapshotJob = job
        do {
            let result = try destination.withAccess { folder in
                try TranscriptExporter().export(
                    contents,
                    preferredName: { TranscriptNaming.fileName(recordedAt: snapshotJob.recordedAt, title: snapshotJob.title, reference: snapshotJob.reference, collision: $0) },
                    reservedName: snapshotJob.reservedName,
                    into: folder)
            }
            job.exportedName = result.fileName
            job.exportedHash = result.contentHash
            job.exportedAt = deps.now()
            job.state = .exported
            job.reason = nil
            job.nextAttemptAt = nil
            try save(job)
            try? FileManager.default.removeItem(at: workDirectory(job))
            Log.shared.info("job \(job.reference): exported")
            return true
        } catch let error as ExportError {
            job.exportAttempts += 1
            switch error {
            case .destinationDenied:
                try schedule(&job, state: .needsFolderAccess, reason: "destination-denied", after: nil)
            case .destinationMissing:
                try schedule(&job, state: .readyToExport, reason: "destination-missing", after: backoff(attempt: job.exportAttempts, base: 30, cap: 600))
            case .writeFailed(let code):
                try schedule(&job, state: .readyToExport, reason: "write-failed-\(code)", after: backoff(attempt: job.exportAttempts, base: 30, cap: 600))
            }
            return false
        }
    }

    // MARK: - User actions

    /// "Transcribe it" for a recording whose age could not be determined.
    public func approve(jobID: Int64) throws {
        guard var job = try deps.store.recording(id: jobID), job.state == .needsDecision else { return }
        job.state = .waitingForSync
        job.reason = "approved-by-user"
        job.observeCount = 1
        job.observedSince = deps.now()
        try save(job)
    }

    /// "Skip" for a recording whose age could not be determined.
    public func skip(jobID: Int64) throws {
        guard var job = try deps.store.recording(id: jobID), job.state == .needsDecision else { return }
        job.state = .excluded
        job.reason = "skipped-by-user"
        try save(job)
    }

    /// Explicit retry of a job that needs the user. A job whose provider no longer matches the
    /// chosen one restarts entirely under the new provider; parts are never mixed.
    public func retry(jobID: Int64) throws {
        guard var job = try deps.store.recording(id: jobID) else { return }
        let retryable: [JobState] = [.needsAttention, .providerOutcomeUnknown, .unsupportedAudio, .needsCredentials, .retryScheduled, .needsFolderAccess, .readyToExport]
        guard retryable.contains(job.state) else { return }
        let current = deps.config.current.provider
        if job.transcript == nil, let provider = job.provider, provider != current {
            try deps.store.deleteChunks(jobID: job.id)
            job.provider = nil
            job.model = nil
        }
        job.attempts = 0
        job.uncertainAttempts = 0
        job.exportAttempts = 0
        job.nextAttemptAt = nil
        job.state = try resumeState(job)
        job.reason = nil
        try save(job)
    }

    public func retryAll() throws {
        for job in try deps.store.recordings(in: [.needsAttention, .providerOutcomeUnknown, .unsupportedAudio, .needsCredentials, .retryScheduled, .needsFolderAccess, .readyToExport]) {
            try retry(jobID: job.id)
        }
    }

    /// Called after the user saves a new key: jobs blocked on the old one may continue.
    public func credentialsChanged(provider: ProviderID) throws {
        try deps.store.setMeta("rejected-key.\(provider.rawValue)", nil)
    }

    /// The output folder changed: unexported results go to the new folder under fresh names.
    public func destinationChanged() throws {
        for var job in try deps.store.recordings(in: [.readyToExport, .needsFolderAccess]) {
            job.reservedName = nil
            job.exportAttempts = 0
            job.nextAttemptAt = nil
            job.state = .readyToExport
            job.reason = nil
            try save(job)
        }
    }

    // MARK: - Status

    private func purgeIfDue() {
        let now = deps.now()
        if let lastPurge, now.timeIntervalSince(lastPurge) < 3600 { return }
        lastPurge = now
        _ = try? deps.store.purgeExportedTranscripts(olderThan: now.addingTimeInterval(-deps.settings.transcriptRetention))
    }

    private func publish(_ next: WorkerStatus) {
        if next != status {
            status = next
            onStatus?(next)
        }
    }

    public func refreshStatus() -> WorkerStatus {
        publish(computeStatus())
        return status
    }

    private func computeStatus() -> WorkerStatus {
        let store = deps.store
        let config = deps.config.current
        guard (try? store.activation()) ?? nil != nil else { return WorkerStatus(phase: .notActivated) }
        let counts = (try? store.stateCounts()) ?? [:]
        let all = (try? store.recordings(in: [.retryScheduled, .readyToExport, .needsAttention, .needsCredentials, .needsFolderAccess])) ?? []
        let last = try? store.lastExported()
        let pendingStates: [JobState] = [.waitingForSync, .preparing, .queued, .transcribing, .readyToExport, .retryScheduled, .needsCredentials, .needsFolderAccess, .sourceChanged]
        let pending = pendingStates.reduce(0) { $0 + (counts[$1] ?? 0) }
        let attention = [JobState.needsAttention, .providerOutcomeUnknown, .unsupportedAudio].reduce(0) { $0 + (counts[$1] ?? 0) }
        let status = WorkerStatus(phase: .watching, pending: pending, attention: attention, undecided: counts[.needsDecision] ?? 0,
                                  lastExportedName: last?.exportedName, lastExportedAt: last?.exportedAt)

        func set(_ phase: WorkerStatus.Phase, _ detail: String? = nil) -> WorkerStatus {
            var s = status
            s.phase = phase
            s.detail = detail
            return s
        }
        if config.paused { return set(.paused) }
        do {
            guard let key = try deps.credentials.key(for: config.provider), !key.isEmpty else { return set(.needsKey, "no-key") }
            if (try? store.meta("rejected-key.\(config.provider.rawValue)")) == Self.keyFingerprint(key) { return set(.needsKey, "key-rejected") }
        } catch {
            return set(.credentialsUnreadable)
        }
        if case .notGranted(let reason) = deps.sourceFolder() { return set(.needsSourceAccess, reason) }
        if sourceScanFailed { return set(.needsSourceAccess, "scan-failed") }
        if case .notGranted(let reason) = deps.destinationFolder() {
            return set(reason == "missing" ? .outputUnavailable : .needsDestinationAccess, reason)
        }
        if all.contains(where: { $0.state == .needsFolderAccess }) { return set(.needsDestinationAccess, "destination-denied") }
        if all.contains(where: { $0.state == .readyToExport && (($0.reason ?? "").hasPrefix("destination") || ($0.reason ?? "").hasPrefix("write-failed")) }) {
            return set(.outputUnavailable, "destination-missing")
        }
        if all.contains(where: { $0.state == .needsCredentials }) { return set(.needsKey, "key-rejected") }
        if all.contains(where: { $0.state == .retryScheduled && $0.reason == "offline" }) { return set(.waitingForInternet) }
        if all.contains(where: { ($0.state == .retryScheduled && $0.reason == "rate-limited") || ($0.state == .needsAttention && $0.reason == "quota") }) {
            return set(.waitingForProviderLimit, all.contains { $0.reason == "quota" } ? "quota" : "rate-limited")
        }
        if attention > 0 { return set(.needsAttention) }
        if (counts[.transcribing] ?? 0) + (counts[.queued] ?? 0) + (counts[.preparing] ?? 0) > 0 { return set(.transcribing) }
        return status
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SQLiteError { return e.description }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
