@preconcurrency import AVFoundation
import Foundation

public struct AudioInfo: Sendable, Equatable {
    public var duration: TimeInterval
    public var isAAC: Bool
    public var sampleRate: Double
    public var channels: Int
}

public enum AudioError: Error, Equatable, CustomStringConvertible {
    case unrecognizedContainer
    case noAudioTrack
    case unreadable(String)
    case encodeFailed(String)
    case canceled

    public var description: String {
        switch self {
        case .unrecognizedContainer: return "unrecognized audio container"
        case .noAudioTrack: return "no audio track"
        case .unreadable(let s): return "audio could not be read (\(s))"
        case .encodeFailed(let s): return "audio could not be prepared (\(s))"
        case .canceled: return "canceled"
        }
    }
}

/// Audio work the worker needs. The production implementation uses AVFoundation only; tests may
/// substitute a fake.
public protocol AudioPipeline: Sendable {
    func inspect(_ url: URL) async throws -> AudioInfo
    func energyProfile(_ url: URL) async throws -> EnergyProfile
    /// Writes the span as a provider-ready `.m4a` (AAC, mono). `passthrough` copies the original
    /// AAC stream without re-encoding when the whole file is used.
    func prepareChunk(source: URL, span: ChunkSpan, passthrough: Bool, to destination: URL) async throws
}

public enum AudioContainer {
    /// Picks an extension from the file's first bytes rather than trusting the name. Voice Memos'
    /// `.qta` files are QuickTime movies; AVFoundation reads them reliably when named `.mov`.
    public static func sniffExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 12 else { return nil }
        let type = String(decoding: head[4..<8], as: UTF8.self)
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        if type == "ftyp" {
            if brand == "qt  " { return "mov" }
            return "m4a"
        }
        if ["moov", "mdat", "wide", "free", "skip"].contains(type) { return "mov" }
        if String(decoding: head[0..<4], as: UTF8.self) == "caff" { return "caf" }
        return nil
    }
}

/// Provider-ready encoding: AAC-LC, mono, 24 kHz, 48 kbit/s (about 21.6 MB per hour). Speech models
/// work at 16 kHz internally, so this keeps quality while staying far below upload caps.
public struct AVFoundationAudioPipeline: AudioPipeline {
    public static let outputSampleRate: Double = 24_000
    public static let outputBitRate = 48_000
    /// Encoded bytes per second including container overhead, for planning.
    public static let plannedBytesPerSecond: Double = Double(outputBitRate) / 8 * 1.04

    public init() {}

    public func inspect(_ url: URL) async throws -> AudioInfo {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration)
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioError.unreadable((error as NSError).localizedDescription)
        }
        guard let track = tracks.first else { throw AudioError.noAudioTrack }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw AudioError.unreadable("zero duration") }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        var isAAC = false
        var sampleRate = 0.0
        var channels = 0
        if let first = descriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            isAAC = asbd.mFormatID == kAudioFormatMPEG4AAC
            sampleRate = asbd.mSampleRate
            channels = Int(asbd.mChannelsPerFrame)
        }
        return AudioInfo(duration: seconds, isAAC: isAAC, sampleRate: sampleRate, channels: channels)
    }

    public func energyProfile(_ url: URL) async throws -> EnergyProfile {
        try await runBlocking {
            let asset = AVURLAsset(url: url)
            let track = try Self.firstAudioTrack(asset)
            let reader = try AVAssetReader(asset: asset)
            let sampleRate = 16_000.0
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings(sampleRate: sampleRate))
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw AudioError.unreadable(reader.error?.localizedDescription ?? "reader") }
            let frameSamples = Int(sampleRate / 10)
            var levels: [Float] = []
            var sum: Double = 0
            var count = 0
            while true {
                if Task.isCancelled { reader.cancelReading(); throw AudioError.canceled }
                let more: Bool = autoreleasepool {
                    guard let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) else { return false }
                    var length = 0
                    var pointer: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                          let pointer else { return true }
                    let samples = length / MemoryLayout<Float>.size
                    pointer.withMemoryRebound(to: Float.self, capacity: samples) { floats in
                        for i in 0..<samples {
                            let s = Double(floats[i])
                            sum += s * s
                            count += 1
                            if count == frameSamples {
                                levels.append(Self.decibels(sum / Double(count)))
                                sum = 0
                                count = 0
                            }
                        }
                    }
                    return true
                }
                if !more { break }
            }
            if count > 0 { levels.append(Self.decibels(sum / Double(count))) }
            if reader.status == .failed { throw AudioError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
            return EnergyProfile(frameDuration: 0.1, levels: levels)
        }
    }

    public func prepareChunk(source: URL, span: ChunkSpan, passthrough: Bool, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        if passthrough, try await remux(source: source, to: destination) { return }
        try await transcode(source: source, span: span, to: destination)
    }

    // MARK: - Internals

    private func remux(source: URL, to destination: URL) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        guard session.supportedFileTypes.contains(.m4a) else { return false }
        session.outputURL = destination
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        if session.status == .completed { return true }
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    private func transcode(source: URL, span: ChunkSpan, to destination: URL) async throws {
        try await runBlocking {
            let asset = AVURLAsset(url: source)
            let track = try Self.firstAudioTrack(asset)
            let reader = try AVAssetReader(asset: asset)
            let timescale: CMTimeScale = 48_000
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: span.start, preferredTimescale: timescale),
                duration: CMTime(seconds: span.duration, preferredTimescale: timescale))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcmSettings(sampleRate: Self.outputSampleRate))
            output.alwaysCopiesSampleData = false
            reader.add(output)

            let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: Self.outputBitRate,
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw AudioError.encodeFailed("settings") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)

            guard reader.startReading() else { throw AudioError.unreadable(reader.error?.localizedDescription ?? "reader") }
            guard writer.startWriting() else { throw AudioError.encodeFailed(writer.error?.localizedDescription ?? "writer") }
            var started = false
            while true {
                if Task.isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw AudioError.canceled
                }
                let more: Bool = try autoreleasepool {
                    guard let buffer = output.copyNextSampleBuffer() else { return false }
                    if !started {
                        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                        started = true
                    }
                    while !input.isReadyForMoreMediaData { usleep(2_000) }
                    if !input.append(buffer) { throw AudioError.encodeFailed(writer.error?.localizedDescription ?? "append") }
                    return true
                }
                if !more { break }
            }
            if reader.status == .failed { throw AudioError.unreadable(reader.error?.localizedDescription ?? "reader failed") }
            guard started else {
                writer.cancelWriting()
                throw AudioError.unreadable("no audio in range")
            }
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else { throw AudioError.encodeFailed(writer.error?.localizedDescription ?? "finish") }
        }
    }

    static func firstAudioTrack(_ asset: AVURLAsset) throws -> AVAssetTrack {
        // Synchronous track access is fine here: this runs on a background thread.
        guard let track = asset.tracks(withMediaType: .audio).first else { throw AudioError.noAudioTrack }
        return track
    }

    static func pcmSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
    }

    static func decibels(_ meanSquare: Double) -> Float {
        guard meanSquare > 1e-12 else { return -120 }
        return Float(10 * log10(meanSquare))
    }

    private func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }
}
