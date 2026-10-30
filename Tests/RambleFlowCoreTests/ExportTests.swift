import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Transcript files")
struct ExportTests {
    let date = ISO8601DateFormatter().date(from: "2026-10-30T10:50:48Z")!
    let zone = TimeZone(identifier: "Asia/Jerusalem")!

    @Test func fileNameAndHeaderFollowTheContract() {
        let name = TranscriptNaming.fileName(recordedAt: date, title: "Meeting notes", reference: "a1b2c3d4", timeZone: zone)
        #expect(name == "2026-10-30 12-50-48 — Meeting notes — a1b2c3d4.txt")
        let doc = TranscriptDocument(title: "Meeting notes", recordedAt: date, dateConfidence: .metadata, duration: 1938, providerName: "Groq",
                                     model: "whisper-large-v3", reference: "a1b2c3d4", text: "Transcript text", noSpeech: false)
        #expect(doc.rendered(timeZone: zone) == """
        Title: Meeting notes
        Recorded: 2026-10-30T12:50:48+02:00
        Duration: 00:32:18
        Transcribed with: Groq / whisper-large-v3
        Recording ID: a1b2c3d4

        Transcript text

        """)
    }

    @Test func hebrewAndMixedTextArePreservedAndNormalized() throws {
        let decomposed = "שלום עולם — cafe\u{0301} meeting"   // é as e + combining accent
        let name = TranscriptNaming.fileName(recordedAt: date, title: decomposed, reference: "a1b2c3d4", timeZone: zone)
        #expect(name.contains("שלום עולם"))
        #expect(name.contains("café"))
        #expect(name == name.precomposedStringWithCanonicalMapping)
        let temp = TempDir("hebrew")
        let text = "זה תמלול בעברית with some English, 123."
        let doc = TranscriptDocument(title: decomposed, recordedAt: date, dateConfidence: .fileName, duration: 5, providerName: "OpenAI", model: "gpt-transcribe", reference: "a1b2c3d4", text: text, noSpeech: false)
        let result = try TranscriptExporter().export(doc.rendered(timeZone: zone), preferredName: { _ in name }, reservedName: nil, into: temp.url)
        let written = try String(contentsOf: temp.url.appendingPathComponent(result.fileName), encoding: .utf8)
        #expect(written.contains(text))
        #expect(written.contains("(time zone assumed)"))
    }

    @Test func unsafeTitlesAreSanitized() {
        #expect(TranscriptNaming.cleanTitle("a/b\\c:d") == "a-b-c-d")
        #expect(TranscriptNaming.cleanTitle("..hidden") == "hidden")
        #expect(TranscriptNaming.cleanTitle("line\nbreak\ttab\u{0007}") == "line break tab")
        #expect(TranscriptNaming.cleanTitle("\u{202E}txt.exe") == "txt.exe", "bidi overrides removed")
        #expect(TranscriptNaming.cleanTitle("   ") == nil)
        #expect(TranscriptNaming.fileName(recordedAt: nil, title: nil, reference: "a1b2c3d4") == "Voice memo — a1b2c3d4.txt")
    }

    @Test func longTitlesAreBoundedInBytesWithoutBreakingCharacters() {
        let title = String(repeating: "הקלטה ארוכה מאוד ", count: 40)
        let name = TranscriptNaming.fileName(recordedAt: date, title: title, reference: "a1b2c3d4", timeZone: zone)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" — a1b2c3d4.txt"))
        #expect(String(name.utf8) == name)
    }

    @Test func sameTitlesGetDistinctNamesByIdentity() {
        let a = TranscriptNaming.fileName(recordedAt: date, title: "Idea", reference: Hashing.shortReference(for: "one"), timeZone: zone)
        let b = TranscriptNaming.fileName(recordedAt: date, title: "Idea", reference: Hashing.shortReference(for: "two"), timeZone: zone)
        #expect(a != b)
    }

    @Test func userFilesAreNeverOverwritten() throws {
        let temp = TempDir("collision")
        let name = "2026-10-30 12-50-48 — Idea — a1b2c3d4.txt"
        try "my own notes".write(to: temp.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let result = try TranscriptExporter().export("transcript", preferredName: { c in TranscriptNaming.fileName(recordedAt: date, title: "Idea", reference: "a1b2c3d4", timeZone: zone, collision: c) }, reservedName: name, into: temp.url)
        #expect(result.fileName == "2026-10-30 12-50-48 — Idea — a1b2c3d4 (2).txt")
        #expect(try String(contentsOf: temp.url.appendingPathComponent(name), encoding: .utf8) == "my own notes")
    }

    @Test func exportIsIdempotent() throws {
        let temp = TempDir("idempotent")
        let exporter = TranscriptExporter()
        let first = try exporter.export("same text", preferredName: { _ in "a.txt" }, reservedName: "a.txt", into: temp.url)
        let second = try exporter.export("same text", preferredName: { _ in "a.txt" }, reservedName: "a.txt", into: temp.url)
        #expect(!first.alreadyPresent)
        #expect(second.alreadyPresent)
        let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(files == ["a.txt"], "no temporary files left behind")
    }

    @Test func permissionLossAndMissingFolderAreReported() throws {
        let temp = TempDir("denied")
        let locked = temp.sub("Locked")
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o755) }
        #expect(throws: ExportError.destinationDenied) {
            try TranscriptExporter().export("x", preferredName: { _ in "a.txt" }, reservedName: nil, into: locked)
        }
        #expect(throws: ExportError.destinationMissing) {
            try TranscriptExporter().export("x", preferredName: { _ in "a.txt" }, reservedName: nil, into: temp.url.appendingPathComponent("Gone"))
        }
    }
}
