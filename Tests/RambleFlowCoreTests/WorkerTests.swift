import Darwin
import Foundation
import Testing
@testable import RambleFlowCore

/// End-to-end worker behaviour with synthetic audio (AVFoundation) and a scripted fake provider.
@Suite("Worker pipeline", .serialized)
struct WorkerTests {
    let speech: [SyntheticAudio.Segment] = [.tone(seconds: 3), .silence(seconds: 1), .tone(seconds: 2, frequency: 660)]

    func fileText(_ h: WorkerHarness) throws -> String {
        let files = h.transcripts()
        #expect(files.count == 1)
        return try String(contentsOf: try #require(files.first), encoding: .utf8)
    }

    @Test func newRecordingBecomesExactlyOneTextFileAndArchiveIsNeverUploaded() async throws {
        let h = try WorkerHarness()
        let provider = h.providers[.groq]!
        // Archive present at setup.
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(-86_400), title: "Old one")
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(-3600), title: "Older")
        try await h.activate()
        h.clock.advance(60)
        // Recorded after setup.
        try h.addRecording(speech, recordedAt: h.clock.now, title: "Planning call")
        h.clock.advance(30)
        let status = await h.settle()

        #expect(provider.callCount == 1)
        let text = try fileText(h)
        #expect(text.hasPrefix("Title: Planning call\nRecorded: "))
        #expect(text.contains("Transcribed with: Groq / whisper-large-v3"))
        #expect(text.hasSuffix("\nsynthetic transcript\n"))
        #expect(h.transcripts().first!.lastPathComponent.contains(" — Planning call — "))
        #expect(status.phase == .watching)
        #expect(try h.store.recordings(in: [.excluded]).count == 2)
        // Work files cleaned up after export.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.paths.work.path)) ?? []).isEmpty)
        // More passes never produce a second file or request.
        await h.settle(passes: 3)
        #expect(provider.callCount == 1)
        #expect(h.transcripts().count == 1)
    }

    @Test func lateSyncedOldRecordingStaysExcluded() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        h.clock.advance(3600)
        // Arrives from iCloud after setup, but was recorded a day before it.
        let url = try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(-86_400 - 3600), title: "Archive")
        setModificationDate(url, h.clock.now)
        await h.settle()
        #expect(h.providers[.groq]!.callCount == 0)
        #expect(h.transcripts().isEmpty)
    }

    @Test func pausePreventsUploadsAndResumeCatchesUp() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.config.update { $0.paused = true }
        h.clock.advance(10)
        try h.addRecording(speech, recordedAt: h.clock.now, title: "While paused")
        h.clock.advance(10)
        #expect(await h.settle().phase == .paused)
        #expect(h.providers[.groq]!.callCount == 0)
        try h.config.update { $0.paused = false }
        await h.settle()
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(h.transcripts().count == 1)
    }

    @Test func overlappingPassesNeverRunTwice() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(5), title: "Concurrent")
        h.clock.advance(20)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = await h.worker.tick() } }
        }
        await h.settle()
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(h.transcripts().count == 1)
    }

    @Test func workerLockExcludesASecondWorker() throws {
        let temp = TempDir("lock")
        let url = temp.url.appendingPathComponent("worker.lock")
        let first = WorkerLock()
        let second = WorkerLock()
        #expect(first.acquire(at: url))
        #expect(!second.acquire(at: url))
        first.release()
        #expect(second.acquire(at: url))
    }

    func longRecordingHarness(script: [FakeProvider.Behavior], maxChunk: TimeInterval = 20) throws -> WorkerHarness {
        let caps = ProviderCapabilities(maxUploadBytes: 25_000_000, targetUploadBytes: 20_000_000, maxChunkDuration: maxChunk, acceptedExtensions: ["m4a"])
        return try WorkerHarness(providers: [.groq: FakeProvider(capabilities: caps, script: script, fallback: .text("part #"))])
    }

    /// 70 seconds of "speech" with pauses, so a 20-second provider limit needs four requests.
    var longSpeech: [SyntheticAudio.Segment] {
        var segments: [SyntheticAudio.Segment] = []
        for i in 0..<7 { segments.append(.tone(seconds: 8.5, frequency: 400 + Double(i) * 40)); segments.append(.silence(seconds: 1.5)) }
        return segments
    }

    @Test func crashBetweenChunksResumesWithoutResendingCompletedParts() async throws {
        let h = try longRecordingHarness(script: [.text("one"), .fail(.canceled)])
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Long")
        await h.worker.tick()            // discovery
        h.clock.advance(20)
        await h.worker.tick()            // part 1 done, then the process "dies" during part 2
        let record = try h.onlyRecord()
        let chunks = try h.store.chunks(jobID: record.id, generation: record.generation)
        #expect(chunks.count >= 4)
        #expect(chunks.filter { $0.status == .done }.count == 1)
        #expect(h.transcripts().isEmpty)

        // "Relaunch": a new worker and a reopened store on the same files.
        h.rebuildWorker(reopenStore: true)
        await h.settle()
        let provider = h.providers[.groq]!
        #expect(provider.callCount == chunks.count + 1, "one canceled request plus each part exactly once")
        let text = try fileText(h)
        #expect(text.contains("one\n\npart 3\n\npart 4"))
    }

    @Test func chunksStayOrderedContiguousAndUnderTheCap() async throws {
        let h = try longRecordingHarness(script: [])
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Ordered")
        h.clock.advance(20)
        await h.settle()
        let record = try h.onlyRecord()
        #expect(record.state == .exported)
        let provider = h.providers[.groq]!
        #expect(provider.calls.allSatisfy { $0.bytes > 0 && $0.bytes < provider.capabilities.maxUploadBytes })
        let chunks = try h.store.chunks(jobID: record.id, generation: record.generation)
        #expect(chunks.first?.start == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(a.end == b.start)
            #expect(a.index + 1 == b.index)
        }
        #expect(abs((chunks.last?.end ?? 0) - 70) < 0.5)
        #expect(chunks.allSatisfy { $0.end - $0.start <= 20.001 })
        // Cuts land in the 1.5-second pauses.
        for chunk in chunks.dropLast() {
            let position = chunk.end.truncatingRemainder(dividingBy: 10)
            #expect(position >= 8.4 && position <= 10.1, "cut at \(chunk.end)")
        }
        let text = try fileText(h)
        let order = (1...chunks.count).map { "part \($0)" }.joined(separator: "\n\n")
        #expect(text.contains(order))
    }

    @Test func transientFailuresRetryOnlyTheFailedPart() async throws {
        let h = try longRecordingHarness(script: [.text("A"), .fail(.server(502)), .fail(.offline)])
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Flaky")
        await h.worker.tick()
        h.clock.advance(20)
        var status = await h.worker.tick()
        #expect(status.phase == .watching || status.phase == .transcribing)
        #expect(try h.onlyRecord().state == .retryScheduled)
        h.clock.advance(60)
        status = await h.worker.tick()
        #expect(status.phase == .waitingForInternet)
        await h.settle(passes: 6, advance: 600)
        let chunks = try h.store.chunks(jobID: try h.onlyRecord().id, generation: 0)
        #expect(h.providers[.groq]!.callCount == chunks.count + 2)
        #expect(try fileText(h).contains("A\n\npart 4"))
    }

    @Test func rateLimitRespectsRetryAfter() async throws {
        let h = try WorkerHarness(providers: [.groq: FakeProvider(script: [.fail(.rateLimited(retryAfter: 120))])])
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        await h.worker.tick()
        h.clock.advance(20)
        #expect(await h.worker.tick().phase == .waitingForProviderLimit)
        h.clock.advance(60)
        await h.worker.tick()
        #expect(h.providers[.groq]!.callCount == 1, "no request before Retry-After")
        h.clock.advance(61)
        await h.settle(passes: 2)
        #expect(h.providers[.groq]!.callCount == 2)
        #expect(h.transcripts().count == 1)
    }

    @Test func quotaExhaustionNeedsAttentionWithoutAHotLoop() async throws {
        let h = try WorkerHarness(providers: [.groq: FakeProvider(script: [.fail(.quotaExhausted("insufficient_quota"))])])
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        h.clock.advance(20)
        let status = await h.settle(passes: 10, advance: 60)
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(status.phase == .waitingForProviderLimit)
        #expect(status.detail == "quota")
        h.clock.advance(3600)
        await h.settle(passes: 2)
        #expect(h.providers[.groq]!.callCount == 2)
        #expect(h.transcripts().count == 1)
    }

    @Test func rejectedKeyPausesUntilTheKeyIsReplaced() async throws {
        let h = try WorkerHarness(providers: [.groq: FakeProvider(script: [.fail(.unauthorized("invalid_api_key"))])])
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        h.clock.advance(20)
        let status = await h.settle(passes: 5, advance: 600)
        #expect(status.phase == .needsKey)
        #expect(h.providers[.groq]!.callCount == 1)
        try h.credentials.setKey("gsk_new_key_1111111111", for: .groq)
        try await h.worker.credentialsChanged(provider: .groq)
        await h.settle(passes: 2)
        #expect(h.providers[.groq]!.callCount == 2)
        #expect(h.providers[.groq]!.calls.last?.key == "gsk_new_key_1111111111")
        #expect(h.transcripts().count == 1)
    }

    @Test func uncertainOutcomesAreBoundedThenSurfaced() async throws {
        let h = try WorkerHarness(providers: [.groq: FakeProvider(script: [.fail(.uncertain("timeout")), .fail(.uncertain("timeout")), .fail(.uncertain("timeout"))])])
        try await h.activate()
        let url = try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        _ = url
        h.clock.advance(20)
        let status = await h.settle(passes: 12, advance: 900)
        #expect(h.providers[.groq]!.callCount == 3)
        #expect(try h.onlyRecord().state == .providerOutcomeUnknown)
        #expect(status.phase == .needsAttention)
        try await h.worker.retry(jobID: try h.onlyRecord().id)
        await h.settle(passes: 2)
        #expect(h.providers[.groq]!.callCount == 4)
        #expect(h.transcripts().count == 1)
    }

    @Test func payloadTooLargeReplansIntoSmallerRequests() async throws {
        let h = try longRecordingHarness(script: [.fail(.payloadTooLarge)], maxChunk: 600)
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Big")
        h.clock.advance(20)
        await h.settle()
        let provider = h.providers[.groq]!
        #expect(provider.callCount == 3, "one 413, then two halves")
        #expect(provider.calls[1].bytes < provider.calls[0].bytes)
        #expect(try h.onlyRecord().maxChunkBytes != nil)
        #expect(h.transcripts().count == 1)
    }

    @Test func exportFailureRetriesOnlyTheExport() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Drive offline")
        try FileManager.default.removeItem(at: h.destination)   // Drive unmounted
        h.clock.advance(20)
        let status = await h.settle(passes: 4, advance: 30)
        #expect(status.phase == .outputUnavailable)
        #expect(try h.onlyRecord().state == .readyToExport)
        #expect(h.providers[.groq]!.callCount == 1)
        try FileManager.default.createDirectory(at: h.destination, withIntermediateDirectories: true)
        await h.settle(passes: 3, advance: 700)
        #expect(h.providers[.groq]!.callCount == 1, "no second transcription")
        #expect(h.transcripts().count == 1)
        // Never fell back to another folder.
        #expect(!FileManager.default.fileExists(atPath: h.temp.url.appendingPathComponent("Documents").path))
    }

    @Test func revokedDestinationPermissionIsRepairedWithoutRetranscribing() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Revoked")
        h.destinationGranted = false
        h.rebuildWorker()
        h.clock.advance(20)
        #expect(await h.settle(passes: 3).phase == .needsDestinationAccess)
        h.destinationGranted = true
        h.rebuildWorker()
        await h.settle(passes: 3)
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(h.transcripts().count == 1)
    }

    @Test func crashAfterTranscriptionBeforeExportExportsOnRelaunch() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Crash")
        h.destinationGranted = false
        h.rebuildWorker()
        h.clock.advance(20)
        await h.settle(passes: 2)
        #expect(try h.onlyRecord().transcript == "synthetic transcript")
        h.destinationGranted = true
        h.rebuildWorker(reopenStore: true)
        await h.settle(passes: 2)
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(h.transcripts().count == 1)
    }

    @Test func providerChangeNeverMixesPartsWithinOneTranscript() async throws {
        let caps = ProviderCapabilities(maxUploadBytes: 25_000_000, targetUploadBytes: 20_000_000, maxChunkDuration: 20, acceptedExtensions: ["m4a"])
        let groq = FakeProvider(id: .groq, capabilities: caps, script: [.text("groq-1"), .fail(.server(500))], fallback: .text("groq #"))
        let openai = FakeProvider(id: .openai, capabilities: caps, fallback: .text("openai #"))
        let h = try WorkerHarness(providers: [.groq: groq, .openai: openai], keys: [.groq: "gsk_key_000000000000", .openai: "sk-key-000000000000"])
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Switch")
        await h.worker.tick()
        h.clock.advance(20)
        await h.worker.tick()   // part 1 done with Groq, part 2 failed
        try h.config.update { $0.provider = .openai }
        await h.settle(passes: 6, advance: 600)
        let text = try fileText(h)
        #expect(text.contains("Transcribed with: Groq / whisper-large-v3"))
        #expect(!text.contains("openai"))
        #expect(openai.callCount == 0)

        // A recording queued after the change uses OpenAI.
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "After switch")
        h.clock.advance(20)
        await h.settle()
        #expect(openai.callCount == 1)
    }

    @Test func removedOldKeyRestartsWholeRecordingUnderNewProviderOnRetry() async throws {
        let caps = ProviderCapabilities(maxUploadBytes: 25_000_000, targetUploadBytes: 20_000_000, maxChunkDuration: 20, acceptedExtensions: ["m4a"])
        let groq = FakeProvider(id: .groq, capabilities: caps, script: [.text("groq-1"), .fail(.server(500))])
        let openai = FakeProvider(id: .openai, capabilities: caps, fallback: .text("openai #"))
        let h = try WorkerHarness(providers: [.groq: groq, .openai: openai], keys: [.groq: "gsk_key_000000000000", .openai: "sk-key-000000000000"])
        try await h.activate()
        try h.addRecording(longSpeech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Restart")
        await h.worker.tick()
        h.clock.advance(20)
        await h.worker.tick()
        try h.config.update { $0.provider = .openai }
        try h.credentials.removeKey(for: .groq)
        h.clock.advance(600)
        await h.worker.tick()
        let record = try h.onlyRecord()
        #expect(record.state == .needsCredentials)
        #expect(record.reason == "provider-changed")
        try await h.worker.retry(jobID: record.id)
        await h.settle()
        let chunkCount = try h.store.chunks(jobID: record.id, generation: record.generation).count
        #expect(openai.callCount == chunkCount)
        let text = try fileText(h)
        #expect(text.contains("Transcribed with: OpenAI / gpt-transcribe"))
        #expect(!text.contains("groq-1"))
    }

    @Test func changedAudioDuringTranscriptionStartsANewGeneration() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        let url = try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Edited")
        let replacement: [SyntheticAudio.Segment] = [.tone(seconds: 4, frequency: 300)]
        let edited = h.temp.url.appendingPathComponent("edited.m4a")
        try SyntheticAudio.write(replacement, to: edited)
        let editedDate = h.clock.now.addingTimeInterval(500)
        // The first upload happens while the recording is replaced by a trimmed version.
        h.providers[.groq]!.push([.hook({ _ in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: edited, to: url)
            setModificationDate(url, editedDate)
            return "old version"
        })])
        h.clock.advance(20)
        await h.settle(passes: 6, advance: 30)
        let record = try h.onlyRecord()
        #expect(record.generation == 1)
        #expect(h.providers[.groq]!.callCount == 2)
        let text = try fileText(h)
        #expect(!text.contains("old version"))
        #expect(text.contains("synthetic transcript"))
    }

    @Test func sameSizeContentChangeIsDetected() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        let url = try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Same size")
        h.providers[.groq]!.push([.hook({ _ in
            // Flip bytes inside the file without changing its size; the modification time moves.
            if let handle = try? FileHandle(forUpdating: url) {
                try? handle.seek(toOffset: 2000)
                handle.write(Data(repeating: 0x55, count: 64))
                try? handle.close()
            }
            setModificationDate(url, Date().addingTimeInterval(1000))
            return "stale"
        })])
        h.clock.advance(20)
        await h.settle(passes: 6, advance: 30)
        #expect(try h.onlyRecord().generation == 1)
        #expect(try !fileText(h).contains("stale"))
    }

    @Test func renamedRecordingIsNotTranscribedTwice() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        let url = try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Rename me")
        h.clock.advance(20)
        await h.settle()
        #expect(h.providers[.groq]!.callCount == 1)
        let renamed = h.source.appendingPathComponent(SyntheticAudio.voiceMemoName(h.clock.now, suffix: "RENAMED1"))
        try FileManager.default.moveItem(at: url, to: renamed)
        var map: [String: RecordingMetadata] = [:]
        if case .available(let m) = h.metadata { map = m }
        map[renamed.deletingPathExtension().lastPathComponent] = RecordingMetadata(recordedAt: h.clock.now, title: "Rename me")
        h.metadata = .available(map)
        await h.settle(passes: 4, advance: 30)
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(h.transcripts().count == 1)
        #expect(try h.store.recordings(in: [.canceled]).contains { $0.reason?.hasPrefix("duplicate-of-") == true })
    }

    @Test func silentRecordingIsAnExplicitNoSpeechResultWithoutUpload() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording([.silence(seconds: 5)], recordedAt: h.clock.now.addingTimeInterval(1), title: "Pocket")
        h.clock.advance(20)
        await h.settle()
        #expect(h.providers[.groq]!.callCount == 0)
        #expect(try fileText(h).hasSuffix("[No speech detected]\n"))
    }

    @Test func corruptAudioIsMarkedUnsupportedAndLeftInPlace() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        let name = SyntheticAudio.voiceMemoName(h.clock.now.addingTimeInterval(1), suffix: "BROKEN01")
        let url = h.source.appendingPathComponent(name)
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: url)
        setModificationDate(url, h.clock.now.addingTimeInterval(2))
        h.metadata = .available([url.deletingPathExtension().lastPathComponent: RecordingMetadata(recordedAt: h.clock.now.addingTimeInterval(1))])
        h.clock.advance(20)
        let status = await h.settle(passes: 10, advance: 3600)
        #expect(try h.onlyRecord().state == .unsupportedAudio)
        #expect(status.phase == .needsAttention)
        #expect(FileManager.default.fileExists(atPath: url.path), "source never deleted")
        #expect(h.providers[.groq]!.callCount == 0)
    }

    @Test func unreadableKeyFileIsNotMistakenForAMissingKey() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        h.credentials.failure = .unreadable(EACCES)
        h.clock.advance(20)
        let status = await h.settle(passes: 3)
        #expect(status.phase == .credentialsUnreadable)
        #expect(try h.onlyRecord().state == .retryScheduled)
        #expect(try h.onlyRecord().reason == "credentials-unreadable")
        h.credentials.failure = nil
        await h.settle(passes: 3, advance: 120)
        #expect(h.transcripts().count == 1)
    }

    @Test func destinationChangeSendsPendingResultsToTheNewFolder() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1), title: "Moved")
        try FileManager.default.removeItem(at: h.destination)
        h.clock.advance(20)
        await h.settle(passes: 2)
        #expect(try h.onlyRecord().state == .readyToExport)
        // User picks a new folder: the old one is not recreated or touched.
        let newFolder = h.temp.sub("NewDestination")
        let providers = h.providers
        let deps = WorkerDependencies(store: h.store, paths: h.paths, config: h.config, credentials: h.credentials, audio: AVFoundationAudioPipeline(),
                                      makeProvider: { id, _ in providers[id]! }, sourceFolder: { [source = h.source] in .available(PlainFolderAccess(url: source)) },
                                      destinationFolder: { .available(PlainFolderAccess(url: newFolder)) }, metadata: { [m = h.metadata] _ in m },
                                      now: { [clock = h.clock] in clock.now }, jitter: { 1 }, settings: h.settings)
        let worker = TranscriptionWorker(dependencies: deps)
        try await worker.destinationChanged()
        await worker.tick()
        #expect(try FileManager.default.contentsOfDirectory(atPath: newFolder.path).count == 1)
        #expect(h.providers[.groq]!.callCount == 1)
    }

    @Test func undecidedRecordingWaitsForTheUser() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(60), withMetadata: false)
        h.clock.advance(120)
        let status = await h.settle(passes: 3)
        #expect(status.undecided == 1)
        #expect(h.providers[.groq]!.callCount == 0)
        try await h.worker.approve(jobID: try h.onlyRecord().id)
        await h.settle(passes: 4)
        #expect(h.providers[.groq]!.callCount == 1)
        #expect(try fileText(h).contains("(time zone assumed)"))
    }

    // MARK: Settings changed by rerunning the installer

    @Test func changingTheRecordingsFolderKeepsNewOnlyForTheNewFolder() async throws {
        let h = try WorkerHarness()
        let provider = h.providers[.groq]!
        let start = h.clock.now
        try await h.activate()
        let cutoff = try #require(try h.store.activation()).cutoff
        // The new folder already holds a recording dated after the cutoff (another library that
        // synced recently): it was there when the folder was switched, so it is never uploaded.
        _ = start
        let other = h.temp.sub("OtherRecordings")
        h.activeSource = other
        h.clock.advance(30)
        try h.addRecording(speech, recordedAt: cutoff.addingTimeInterval(10), title: "Already there")
        h.clock.advance(5)
        await h.settle()
        #expect(provider.callCount == 0, "a recording already in the new folder is part of the baseline")
        #expect(try h.store.recordings().allSatisfy { $0.state == .excluded })
        // A recording made afterwards in the new folder is transcribed.
        h.clock.advance(60)
        try h.addRecording(speech, recordedAt: h.clock.now, title: "After the change")
        h.clock.advance(5)
        await h.settle()
        #expect(provider.callCount == 1)
        #expect(h.transcripts().count == 1)
        #expect(try h.store.activation()?.cutoff == cutoff, "the cutoff never moves")
    }

    @Test func modelAndLanguageChangesApplyToRecordingsNotStartedYet() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.config.update { $0.model = "whisper-large-v3-turbo"; $0.languageHint = "he" }
        h.config.reload()
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        h.clock.advance(5)
        await h.settle()
        let record = try h.onlyRecord()
        #expect(record.state == .exported)
        #expect(record.model == "whisper-large-v3-turbo")
        #expect(record.language == "he")
        #expect(h.providers[.groq]!.calls.first?.language == "he")
        #expect(try fileText(h).contains("Transcribed with: Groq / whisper-large-v3-turbo"))
    }

    @Test func destinationChangeInSettingsIsFollowedByTheWorker() async throws {
        let h = try WorkerHarness()
        try await h.activate()
        try h.config.update { $0.destinationPath = h.destination.path }
        await h.settle(passes: 1)
        h.destinationGranted = false
        try h.addRecording(speech, recordedAt: h.clock.now.addingTimeInterval(1))
        h.clock.advance(5)
        await h.settle()
        #expect(try h.onlyRecord().state == .needsFolderAccess)
        // The installer is rerun with another transcripts folder.
        try h.config.update { $0.destinationPath = h.temp.url.appendingPathComponent("Elsewhere").path }
        h.config.reload()
        h.destinationGranted = true
        await h.settle()
        #expect(try h.onlyRecord().state == .exported)
        #expect(h.providers[.groq]!.callCount == 1, "a changed folder never causes a second transcription")
    }
}
