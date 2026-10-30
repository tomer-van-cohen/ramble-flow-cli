import Darwin
import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Configuration, credentials and schema")
struct ConfigTests {
    @Test func freshConfigurationDefaults() {
        let temp = TempDir("config")
        let config = ConfigStore(url: temp.url.appendingPathComponent("config.json")).current
        #expect(config.provider == .groq)
        #expect(config.languageHint == nil, "automatic language detection; no global language forced")
        #expect(!config.paused)
        #expect(!config.setupCompleted)
        #expect(ProviderID.groq.defaultModel == "whisper-large-v3")
        #expect(ProviderID.openai.defaultModel == "gpt-transcribe")
    }

    @Test func settingsFileHoldsNoKeyAndIsPrivate() throws {
        let temp = TempDir("partial")
        let url = temp.url.appendingPathComponent("config.json")
        try ConfigStore(url: url).update {
            $0.sourcePath = "/tmp/Recordings"
            $0.languageHint = "he"
        }
        let reloaded = ConfigStore(url: url).current
        #expect(reloaded.sourcePath == "/tmp/Recordings")
        #expect(reloaded.destinationPath == nil)
        #expect(!reloaded.setupCompleted)
        #expect(reloaded.effectiveModel == "whisper-large-v3")
        #expect(!(try String(contentsOf: url, encoding: .utf8)).lowercased().contains("key"), "no API key in the settings file")
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func settingsChangedByAnotherProcessAreReloaded() throws {
        let temp = TempDir("reload")
        let url = temp.url.appendingPathComponent("config.json")
        let daemonView = ConfigStore(url: url)
        #expect(!daemonView.current.paused)
        // The installer or `ramble-flow pause` writes through its own store.
        try ConfigStore(url: url).update { $0.paused = true; $0.provider = .openai; $0.model = "custom-model" }
        daemonView.reload()
        #expect(daemonView.current.paused)
        #expect(daemonView.current.provider == .openai)
        #expect(daemonView.current.effectiveModel == "custom-model")
    }

    @Test func unreadableSettingsKeepTheLastGoodValues() throws {
        let temp = TempDir("garbage")
        let url = temp.url.appendingPathComponent("config.json")
        let store = ConfigStore(url: url)
        try store.update { $0.languageHint = "en" }
        try Data("{ not json".utf8).write(to: url)
        store.reload()
        #expect(store.current.languageHint == "en")
    }

    @Test func keyFileIsPrivateAtomicAndRoundTrips() throws {
        let temp = TempDir("keys")
        let url = temp.url.appendingPathComponent("Support/secrets.env")
        let store = KeyFileStore(url: url, environment: [:])
        #expect(try store.key(for: .groq) == nil)
        try store.setKey("gsk_test_0000000000000000000000", for: .groq)
        try store.setKey("sk-test-1111111111111111111111", for: .openai)
        #expect(try store.key(for: .groq) == "gsk_test_0000000000000000000000")
        #expect(try store.key(for: .openai) == "sk-test-1111111111111111111111")
        #expect(store.permissions() == 0o600)
        let folderMode = (try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(folderMode == 0o700)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("GROQ_API_KEY=gsk_test_0000000000000000000000"))
        #expect(text.hasPrefix("#"), "the file explains itself")
        // No temporary files are left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
        try store.removeKey(for: .groq)
        #expect(try store.key(for: .groq) == nil)
        #expect(try store.key(for: .openai) != nil)
        try store.removeKey(for: .openai)
        #expect(!FileManager.default.fileExists(atPath: url.path), "an empty key file is removed")
    }

    @Test func environmentVariableOverridesTheFile() throws {
        let temp = TempDir("env")
        let url = temp.url.appendingPathComponent("secrets.env")
        try KeyFileStore(url: url, environment: [:]).setKey("gsk_file_00000000000000000000", for: .groq)
        let overridden = KeyFileStore(url: url, environment: ["GROQ_API_KEY": "gsk_env_111111111111111111111", "OPENAI_API_KEY": "  "])
        #expect(try overridden.key(for: .groq) == "gsk_env_111111111111111111111")
        #expect(try overridden.fileKey(for: .groq) == "gsk_file_00000000000000000000")
        #expect(overridden.environmentOverrides(.groq))
        #expect(!overridden.environmentOverrides(.openai), "an empty variable does not override")
        #expect(try overridden.key(for: .openai) == nil)
    }

    @Test func keyFileParsingToleratesHandEdits() {
        let parsed = KeyFileStore.parse("""
        # comment
        export GROQ_API_KEY = "gsk_quoted_000000000000000000"

        OPENAI_API_KEY='sk-single-00000000000000000000'
        garbage line
        """)
        #expect(parsed["GROQ_API_KEY"] == "gsk_quoted_000000000000000000")
        #expect(parsed["OPENAI_API_KEY"] == "sk-single-00000000000000000000")
        #expect(parsed.count == 2)
    }

    @Test func unreadableKeyFileIsNotMistakenForNoKey() throws {
        let temp = TempDir("unreadable")
        let url = temp.url.appendingPathComponent("secrets.env")
        let store = KeyFileStore(url: url, environment: [:])
        try store.setKey("gsk_test_0000000000000000000000", for: .groq)
        chmod(url.path, 0o000)
        defer { chmod(url.path, 0o600) }
        guard getuid() != 0 else { return }
        #expect(throws: CredentialError.self) { try store.key(for: .groq) }
    }

    @Test func memoryCredentialStoreReportsUnavailability() throws {
        let store = MemoryCredentialStore([.groq: "gsk_x"])
        #expect(try store.key(for: .groq) == "gsk_x")
        store.failure = .unreadable(EACCES)
        #expect(throws: CredentialError.unreadable(EACCES)) { try store.key(for: .groq) }
    }

    @Test func schemaMigratesFromVersionOneKeepingRows() throws {
        let temp = TempDir("migrate")
        let url = temp.url.appendingPathComponent("jobs.sqlite")
        do {
            let db = try SQLiteConnection(path: url.path)
            try db.execute(JobStore.migrations[0])
            try db.execute("PRAGMA user_version = 1")
            try db.run("""
                INSERT INTO recordings (stem, file_name, reference, date_confidence, state, observed_size, observed_mtime, observe_count, observed_since, first_seen_at, updated_at)
                VALUES ('20261030 101010-AAAA0001', '20261030 101010-AAAA0001.m4a', 'abcd1234', 'metadata', 'exported', 10, 1, 2, 1, 1, 1)
                """)
            try db.run("INSERT INTO meta(key, value) VALUES ('cutoff', '1800000000'), ('activated_at', '1800000000')")
        }
        let store = try JobStore(url: url)
        #expect(try store.userVersion() == JobStore.schemaVersion)
        let record = try #require(try store.recording(stem: "20261030 101010-AAAA0001"))
        #expect(record.state == .exported)
        #expect(record.maxChunkBytes == nil)
        #expect(record.sourceIsAAC == false)
        #expect(try store.activation()?.cutoff == Date(timeIntervalSince1970: 1_800_000_000))
        // Opening again is a no-op.
        #expect(try JobStore(url: url).userVersion() == JobStore.schemaVersion)
    }

    @Test func retentionDropsOnlyOldExportedText() throws {
        let temp = TempDir("retention")
        let store = try JobStore(url: temp.url.appendingPathComponent("jobs.sqlite"))
        let now = Date()
        var old = RecordingRecord(stem: "old", fileName: "old.m4a", now: now)
        old.state = .exported
        old.transcript = "text"
        old.exportedAt = now.addingTimeInterval(-8 * 86_400)
        var pending = RecordingRecord(stem: "pending", fileName: "pending.m4a", now: now)
        pending.state = .readyToExport
        pending.transcript = "keep me"
        try store.save(old)
        try store.save(pending)
        #expect(try store.purgeExportedTranscripts(olderThan: now.addingTimeInterval(-7 * 86_400)) == 1)
        #expect(try store.recording(stem: "old")?.transcript == nil)
        #expect(try store.recording(stem: "pending")?.transcript == "keep me")
    }
}
