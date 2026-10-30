@preconcurrency import AVFoundation
import Foundation
@testable import RambleFlowCore

/// A fresh temporary directory per test, removed by `cleanup()`.
final class TempDir {
    let url: URL

    init(_ label: String = "test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ramble-flow-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func sub(_ name: String) -> URL {
        let child = url.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        return child
    }

    deinit {
        // Restore permissions changed by tests so cleanup can proceed.
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let path as String in enumerator {
                chmod(url.appendingPathComponent(path).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Synthetic audio: tone bursts (stand-ins for speech) and silence, written with AVFoundation.
/// No real recordings are used anywhere in the tests.
enum SyntheticAudio {
    enum Segment {
        case tone(seconds: Double, frequency: Double = 440)
        case silence(seconds: Double)
    }

    enum Container {
        /// MPEG-4 audio (`.m4a`).
        case m4a
        /// QuickTime movie, as Voice Memos writes for `.qta` files.
        case quickTime
    }

    static func write(_ segments: [Segment], to url: URL, container: Container = .m4a, sampleRate: Double = 16_000) throws {
        try? FileManager.default.removeItem(at: url)
        // AVAssetWriter insists on a matching extension; write then rename.
        let staging = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + (container == .m4a ? ".m4a" : ".mov"))
        let writer = try AVAssetWriter(outputURL: staging, fileType: container == .m4a ? .m4a : .mov)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AudioError.encodeFailed("start") }
        writer.startSession(atSourceTime: .zero)

        var position: Int64 = 0
        let block = Int(sampleRate / 10)
        for segment in segments {
            let (seconds, frequency): (Double, Double?) = {
                switch segment {
                case .tone(let s, let f): return (s, f)
                case .silence(let s): return (s, nil)
                }
            }()
            var remaining = Int(seconds * sampleRate)
            while remaining > 0 {
                let n = min(block, remaining)
                var samples = [Float](repeating: 0, count: n)
                if let frequency {
                    for i in 0..<n {
                        let t = Double(position + Int64(i)) / sampleRate
                        // A warbling tone with an amplitude envelope, loud enough to count as speech.
                        samples[i] = Float(0.3 * sin(2 * .pi * frequency * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t)))
                    }
                }
                var blockBuffer: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 4, blockAllocator: nil, customBlockSource: nil,
                                                   offsetToData: 0, dataLength: n * 4, flags: 0, blockBufferOut: &blockBuffer)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: n * 4) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blockBuffer!, formatDescription: format!, sampleCount: n,
                                                                     presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(sampleRate)),
                                                                     packetDescriptions: nil, sampleBufferOut: &sample)
                while !input.isReadyForMoreMediaData { usleep(500) }
                guard input.append(sample!) else { throw writer.error ?? AudioError.encodeFailed("append") }
                position += Int64(n)
                remaining -= n
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? AudioError.encodeFailed("finish") }
        try FileManager.default.moveItem(at: staging, to: url)
    }

    /// Voice Memos style file name for a wall-clock time.
    static func voiceMemoName(_ date: Date, suffix: String = UUID().uuidString.prefix(8).uppercased(), ext: String = "m4a", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return "\(formatter.string(from: date))-\(suffix).\(ext)"
    }
}

/// Scripted provider: each call pops the next behavior; records what was sent.
final class FakeProvider: TranscriptionProvider, @unchecked Sendable {
    enum Behavior {
        case text(String)
        case fail(ProviderError)
        case hook(@Sendable (URL) throws -> String)
    }

    let id: ProviderID
    let model: String
    let capabilities: ProviderCapabilities
    private let lock = NSLock()
    private var script: [Behavior]
    private var fallback: Behavior
    private(set) var calls: [(bytes: Int, language: String?, key: String)] = []

    init(id: ProviderID = .groq, capabilities: ProviderCapabilities? = nil, script: [Behavior] = [], fallback: Behavior = .text("synthetic transcript")) {
        self.id = id
        self.model = id.defaultModel
        self.capabilities = capabilities ?? ProviderCapabilities(maxUploadBytes: 25_000_000, targetUploadBytes: 20_000_000, maxChunkDuration: 1800, acceptedExtensions: ["m4a"])
        self.script = script
        self.fallback = fallback
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }

    func push(_ behaviors: [Behavior]) {
        lock.lock()
        script.append(contentsOf: behaviors)
        lock.unlock()
    }

    func transcribe(audio: URL, language: String?, apiKey: String) async throws -> ProviderTranscript {
        let size = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        lock.lock()
        calls.append((size, language, apiKey))
        let behavior = script.isEmpty ? fallback : script.removeFirst()
        let callNumber = calls.count
        lock.unlock()
        switch behavior {
        case .text(let text): return ProviderTranscript(text: text.replacingOccurrences(of: "#", with: "\(callNumber)"))
        case .fail(let error): throw error
        case .hook(let body): return ProviderTranscript(text: try body(audio))
        }
    }

    func checkKey(_ apiKey: String) async -> KeyCheck { .accepted }
}

/// Scripted HTTP transport for provider contract tests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Captured {
        var request: URLRequest
        var body: Data
    }

    private let lock = NSLock()
    var responses: [Result<HTTPResponse, Error>]
    private(set) var captured: [Captured] = []

    init(_ responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> HTTPResponse {
        let body = bodyFile.flatMap { try? Data(contentsOf: $0) } ?? Data()
        lock.lock()
        captured.append(Captured(request: request, body: body))
        let next = responses.isEmpty ? .success(HTTPResponse(status: 200, body: Data(#"{"text":""}"#.utf8))) : responses.removeFirst()
        lock.unlock()
        return try next.get()
    }

    static func json(_ status: Int, _ object: String, headers: [String: String] = [:]) -> Result<HTTPResponse, Error> {
        .success(HTTPResponse(status: status, headers: headers, body: Data(object.utf8)))
    }
}

/// A complete worker wired to temporary folders, a fake provider and in-memory credentials.
final class WorkerHarness {
    let temp = TempDir("worker")
    let source: URL
    let destination: URL
    let paths: AppPaths
    let store: JobStore
    let config: ConfigStore
    let credentials: MemoryCredentialStore
    var providers: [ProviderID: FakeProvider]
    let clock: TestClock
    var metadata: MetadataSnapshot = .unavailable(reason: "test")
    var destinationGranted = true
    /// Folder the worker currently reads (tests may switch it, as a settings change would).
    var activeSource: URL?
    var settings = WorkerSettings()
    private(set) var worker: TranscriptionWorker!

    init(providers: [ProviderID: FakeProvider] = [.groq: FakeProvider()], keys: [ProviderID: String] = [.groq: "gsk_test_key_0000000000"], start: Date = Date()) throws {
        source = temp.sub("Recordings")
        destination = temp.sub("Transcripts")
        paths = AppPaths(root: temp.sub("Support"))
        try paths.createDirectories()
        store = try JobStore(url: paths.database)
        config = ConfigStore(url: paths.config)
        credentials = MemoryCredentialStore(keys)
        self.providers = providers
        clock = TestClock(start)
        settings.stabilityWindow = 0
        settings.missingGrace = 30
        rebuildWorker()
    }

    /// A new worker and job store on the same files: what a relaunch after a crash sees.
    func rebuildWorker(reopenStore: Bool = false) {
        let store = reopenStore ? (try! JobStore(url: paths.database)) : self.store
        let providers = self.providers
        let source = self.source
        let destination = self.destination
        let deps = WorkerDependencies(
            store: store, paths: paths, config: config, credentials: credentials, audio: AVFoundationAudioPipeline(),
            makeProvider: { id, _ in providers[id] ?? FakeProvider(id: id) },
            sourceFolder: { [weak self] in .available(PlainFolderAccess(url: self?.activeSource ?? source)) },
            destinationFolder: { [weak self] in
                (self?.destinationGranted ?? true) ? .available(PlainFolderAccess(url: destination)) : .notGranted("test")
            },
            metadata: { [weak self] _ in self?.metadata ?? .unavailable(reason: "test") },
            now: { [clock] in clock.now },
            jitter: { 1.0 },
            settings: settings)
        worker = TranscriptionWorker(dependencies: deps)
    }

    func activate() async throws {
        try await worker.activate()
    }

    /// Runs passes until nothing changes (bounded).
    @discardableResult
    func settle(passes: Int = 6, advance: TimeInterval = 1) async -> WorkerStatus {
        var status = await worker.tick()
        for _ in 1..<passes {
            clock.advance(advance)
            status = await worker.tick()
        }
        return status
    }

    func transcripts() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func onlyRecord() throws -> RecordingRecord {
        let all = try store.recordings().filter { $0.state != .excluded }
        precondition(all.count == 1, "expected one recording, found \(all.count)")
        return all[0]
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

func setModificationDate(_ url: URL, _ date: Date) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

extension WorkerHarness {
    /// Writes a synthetic recording into the source folder and registers Voice Memos style metadata
    /// for it (as the read-only library adapter would report).
    @discardableResult
    func addRecording(_ segments: [SyntheticAudio.Segment], recordedAt: Date, title: String? = nil, container: SyntheticAudio.Container = .m4a,
                      withMetadata: Bool = true, name: String? = nil) throws -> URL {
        let ext = container == .m4a ? "m4a" : "qta"
        let fileName = name ?? SyntheticAudio.voiceMemoName(recordedAt, ext: ext)
        let url = (activeSource ?? source).appendingPathComponent(fileName)
        try SyntheticAudio.write(segments, to: url, container: container)
        let duration = segments.reduce(0.0) { total, segment in
            switch segment {
            case .tone(let s, _), .silence(let s): return total + s
            }
        }
        setModificationDate(url, recordedAt.addingTimeInterval(duration))
        if withMetadata {
            var map: [String: RecordingMetadata] = [:]
            if case .available(let existing) = metadata { map = existing }
            map[url.deletingPathExtension().lastPathComponent] = RecordingMetadata(uniqueID: UUID().uuidString, recordedAt: recordedAt, duration: duration, title: title)
            metadata = .available(map)
        }
        return url
    }
}
