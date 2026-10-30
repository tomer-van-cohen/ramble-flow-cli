import Darwin
import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Audio preparation (synthetic media)", .serialized)
struct AudioTests {
    let pipeline = AVFoundationAudioPipeline()

    @Test func quickTimeQtaAndM4AAreRecognizedByContentNotName() async throws {
        let temp = TempDir("formats")
        let qta = temp.url.appendingPathComponent("20261030 101010-AAAA0001.qta")
        let m4a = temp.url.appendingPathComponent("20261030 101011-AAAA0002.m4a")
        try SyntheticAudio.write([.tone(seconds: 2)], to: qta, container: .quickTime)
        try SyntheticAudio.write([.tone(seconds: 2)], to: m4a, container: .m4a)
        #expect(AudioContainer.sniffExtension(of: qta) == "mov")
        #expect(AudioContainer.sniffExtension(of: m4a) == "m4a")
        // Snapshot copies get the sniffed extension, as the worker does.
        let snapshot = temp.url.appendingPathComponent("snapshot.mov")
        try FileManager.default.copyItem(at: qta, to: snapshot)
        let info = try await pipeline.inspect(snapshot)
        #expect(abs(info.duration - 2) < 0.2)
        #expect(info.isAAC)
        let out = temp.url.appendingPathComponent("out.m4a")
        try await pipeline.prepareChunk(source: snapshot, span: ChunkSpan(start: 0, end: info.duration), passthrough: true, to: out)
        let outInfo = try await pipeline.inspect(out)
        #expect(abs(outInfo.duration - 2) < 0.2)
        #expect(AudioContainer.sniffExtension(of: out) == "m4a")
    }

    @Test func corruptAudioIsRejected() async throws {
        let temp = TempDir("corrupt")
        let junk = temp.url.appendingPathComponent("junk.m4a")
        try Data(repeating: 0x42, count: 10_000).write(to: junk)
        #expect(AudioContainer.sniffExtension(of: junk) == nil)
        // A valid header with a truncated body.
        let good = temp.url.appendingPathComponent("good.m4a")
        try SyntheticAudio.write([.tone(seconds: 3)], to: good)
        let truncated = temp.url.appendingPathComponent("truncated.m4a")
        try (try Data(contentsOf: good)).prefix(600).write(to: truncated)
        await #expect(throws: (any Error).self) { _ = try await pipeline.inspect(truncated) }
    }

    @Test func transcodedChunksAreMonoAACAtTheSpeechRate() async throws {
        let temp = TempDir("transcode")
        let source = temp.url.appendingPathComponent("s.m4a")
        try SyntheticAudio.write([.tone(seconds: 6), .silence(seconds: 2), .tone(seconds: 6)], to: source, sampleRate: 44_100)
        let out = temp.url.appendingPathComponent("chunk.m4a")
        try await pipeline.prepareChunk(source: source, span: ChunkSpan(start: 4, end: 10), passthrough: false, to: out)
        let info = try await pipeline.inspect(out)
        #expect(abs(info.duration - 6) < 0.3)
        #expect(info.channels == 1)
        #expect(info.sampleRate == AVFoundationAudioPipeline.outputSampleRate)
        let bytes = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        #expect(Double(bytes) < 6 * AVFoundationAudioPipeline.plannedBytesPerSecond * 1.3)
    }

    @Test func energyProfileFindsSilence() async throws {
        let temp = TempDir("energy")
        let source = temp.url.appendingPathComponent("s.m4a")
        try SyntheticAudio.write([.tone(seconds: 3), .silence(seconds: 2), .tone(seconds: 3)], to: source)
        let profile = try await pipeline.energyProfile(source)
        #expect(abs(Double(profile.levels.count) * profile.frameDuration - 8) < 0.3)
        #expect(profile.isSilent(ChunkSpan(start: 3.3, end: 4.7)))
        #expect(!profile.isSilent(ChunkSpan(start: 0.5, end: 2.5)))
    }

    @Test func plannerRespectsTimeAndByteLimitsAndPrefersQuietCuts() {
        // 1 hour, a pause every 50 seconds.
        var levels: [Float] = []
        for i in 0..<36_000 { levels.append(i % 500 >= 490 ? -90 : -20) }
        let energy = EnergyProfile(frameDuration: 0.1, levels: levels)
        let limits = ChunkPlanner.Limits(maxDuration: 600, targetBytes: 20_000_000, bytesPerSecond: 6240)
        let spans = ChunkPlanner.plan(duration: 3600, energy: energy, limits: limits)
        #expect(spans.first?.start == 0)
        #expect(spans.last?.end == 3600)
        #expect(spans.allSatisfy { $0.duration <= 600 + 0.001 && $0.duration > 0 })
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(a.end == b.start) }
        for span in spans.dropLast() {
            let inCycle = span.end.truncatingRemainder(dividingBy: 50)
            #expect(inCycle >= 48.9 || inCycle < 0.2, "cut at \(span.end) is not in a pause")
        }
        // A byte budget smaller than the time limit wins.
        let tight = ChunkPlanner.Limits(maxDuration: 1800, targetBytes: 2_000_000, bytesPerSecond: 6240)
        #expect(ChunkPlanner.plan(duration: 3600, energy: nil, limits: tight).allSatisfy { Double($0.duration) * 6240 <= 2_000_000 })
        #expect(ChunkPlanner.plan(duration: 30, energy: nil, limits: limits) == [ChunkSpan(start: 0, end: 30)])
        #expect(ChunkPlanner.plan(duration: 0, energy: nil, limits: limits).isEmpty)
    }

    @Test func splittingKeepsCoverage() {
        let span = ChunkSpan(start: 100, end: 200)
        let halves = ChunkPlanner.split(span, energy: nil)
        #expect(halves == [ChunkSpan(start: 100, end: 150), ChunkSpan(start: 150, end: 200)])
    }

    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    @Test func longRecordingIsProcessedWithBoundedMemory() async throws {
        let temp = TempDir("long")
        let source = temp.url.appendingPathComponent("long.m4a")
        // 40 minutes: 55 s of tone, 5 s of silence, repeated.
        var segments: [SyntheticAudio.Segment] = []
        for _ in 0..<40 { segments.append(.tone(seconds: 55)); segments.append(.silence(seconds: 5)) }
        try SyntheticAudio.write(segments, to: source)
        let before = Self.residentBytes()
        let info = try await pipeline.inspect(source)
        #expect(abs(info.duration - 2400) < 1)
        let profile = try await pipeline.energyProfile(source)
        let spans = ChunkPlanner.plan(duration: info.duration, energy: profile,
                                      limits: .init(maxDuration: 1200, targetBytes: 20_000_000, bytesPerSecond: AVFoundationAudioPipeline.plannedBytesPerSecond))
        #expect(spans.count >= 2 && spans.count <= 3)
        #expect(spans.allSatisfy { $0.duration <= 1200.001 })
        #expect(profile.isSilent(ChunkSpan(start: spans[0].end - 0.2, end: spans[0].end + 0.2)), "first cut lands in a pause")
        let out = temp.url.appendingPathComponent("part.m4a")
        try await pipeline.prepareChunk(source: source, span: spans[0], passthrough: false, to: out)
        let bytes = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int
        #expect(bytes < 20_000_000)
        let growth = Self.residentBytes() - before
        #expect(growth < 150_000_000, "resident memory grew by \(growth / 1_000_000) MB")
    }
}
