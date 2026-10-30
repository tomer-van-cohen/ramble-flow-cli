import Foundation
import SQLite3
import Testing
@testable import RambleFlowCore

@Suite("Discovery and source metadata")
struct DiscoveryTests {
    let cutoff = Date(timeIntervalSince1970: 1_800_000_000)

    func makeStore(_ temp: TempDir) throws -> JobStore {
        let store = try JobStore(url: temp.url.appendingPathComponent("jobs.sqlite"))
        try store.activate(cutoff: cutoff, baselineStems: [], now: cutoff)
        return store
    }

    func file(_ folder: URL, _ name: String, bytes: Int, modified: Date) -> SourceFile {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: bytes))
        setModificationDate(url, modified)
        return SourceFile(url: url, size: Int64(bytes), modified: modified)
    }

    @Test func listingIgnoresWaveformsTemporaryFilesFoldersAndOtherFormats() throws {
        let temp = TempDir("listing")
        let folder = temp.sub("Recordings")
        for name in ["20261030 101010-AAAA0001.m4a", "20261030 101011-AAAA0002.qta", "20261030 101010-AAAA0001.waveform",
                     ".20261030 101012-AAAA0003.m4a", "20261030 101013-AAAA0004.m4a.icloud", "notes.txt", "x.tmp", "CloudRecordings.db"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([1]))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Capture.m4a"), withIntermediateDirectories: true)
        let names = try VoiceMemosSource.listRecordings(in: folder).map(\.fileName)
        #expect(names == ["20261030 101010-AAAA0001.m4a", "20261030 101011-AAAA0002.qta"])
    }

    @Test func ongoingWriteWaitsUntilSizeAndTimeHoldStill() throws {
        let temp = TempDir("stability")
        let store = try makeStore(temp)
        let discovery = RecordingDiscovery(store: store, policy: EligibilityPolicy(cutoff: cutoff), stabilityWindow: 15)
        let folder = temp.sub("Recordings")
        let recorded = cutoff.addingTimeInterval(600)
        let meta = MetadataSnapshot.available(["20330518 033320-AAAA0001": RecordingMetadata(recordedAt: recorded)])
        var now = cutoff.addingTimeInterval(700)

        var f = file(folder, "20330518 033320-AAAA0001.m4a", bytes: 1000, modified: now)
        try discovery.reconcile(files: [f], metadata: meta, now: now)
        #expect(try store.recording(stem: f.stem)?.state == .waitingForSync)

        now += 10
        f = file(folder, f.fileName, bytes: 2000, modified: now)   // still growing
        try discovery.reconcile(files: [f], metadata: meta, now: now)
        #expect(try store.recording(stem: f.stem)?.state == .waitingForSync)

        now += 10   // same size and time, but the window has not elapsed since the last change
        try discovery.reconcile(files: [f], metadata: meta, now: now)
        #expect(try store.recording(stem: f.stem)?.state == .waitingForSync)

        now += 10
        try discovery.reconcile(files: [f], metadata: meta, now: now)
        #expect(try store.recording(stem: f.stem)?.state == .preparing)
    }

    @Test func zeroBytePlaceholderNeverBecomesStable() throws {
        let temp = TempDir("placeholder")
        let store = try makeStore(temp)
        let discovery = RecordingDiscovery(store: store, policy: EligibilityPolicy(cutoff: cutoff), stabilityWindow: 0)
        let folder = temp.sub("Recordings")
        let f = file(folder, "20330518 033320-AAAA0001.m4a", bytes: 0, modified: cutoff.addingTimeInterval(100))
        let meta = MetadataSnapshot.available([f.stem: RecordingMetadata(recordedAt: cutoff.addingTimeInterval(50))])
        for step in 0..<5 {
            try discovery.reconcile(files: [f], metadata: meta, now: cutoff.addingTimeInterval(200 + Double(step) * 10))
        }
        let record = try #require(try store.recording(stem: f.stem))
        #expect(record.state == .waitingForSync)
        #expect(record.reason == "placeholder")
    }

    @Test func deletedSourceIsCanceledAfterAGracePeriodOnly() throws {
        let temp = TempDir("deleted")
        let store = try makeStore(temp)
        let discovery = RecordingDiscovery(store: store, policy: EligibilityPolicy(cutoff: cutoff), stabilityWindow: 0, missingGrace: 60)
        let folder = temp.sub("Recordings")
        let f = file(folder, "20330518 033320-AAAA0001.m4a", bytes: 10, modified: cutoff.addingTimeInterval(100))
        let meta = MetadataSnapshot.available([f.stem: RecordingMetadata(recordedAt: cutoff.addingTimeInterval(50))])
        try discovery.reconcile(files: [f], metadata: meta, now: cutoff.addingTimeInterval(200))
        try discovery.reconcile(files: [], metadata: meta, now: cutoff.addingTimeInterval(210))
        #expect(try store.recording(stem: f.stem)?.state == .waitingForSync)
        #expect(try store.recording(stem: f.stem)?.reason == "source-missing")
        try discovery.reconcile(files: [], metadata: meta, now: cutoff.addingTimeInterval(240))
        #expect(try store.recording(stem: f.stem)?.state == .waitingForSync)
        try discovery.reconcile(files: [], metadata: meta, now: cutoff.addingTimeInterval(280))
        #expect(try store.recording(stem: f.stem)?.state == .canceled)
        #expect(try store.recording(stem: f.stem)?.reason == "source-deleted")
    }

    @Test func recordingMovedToRecentlyDeletedIsCanceled() throws {
        let temp = TempDir("trash")
        let store = try makeStore(temp)
        let discovery = RecordingDiscovery(store: store, policy: EligibilityPolicy(cutoff: cutoff), stabilityWindow: 0)
        let folder = temp.sub("Recordings")
        let f = file(folder, "20330518 033320-AAAA0001.m4a", bytes: 10, modified: cutoff.addingTimeInterval(100))
        try discovery.reconcile(files: [f], metadata: .available([f.stem: RecordingMetadata(recordedAt: cutoff.addingTimeInterval(50))]), now: cutoff.addingTimeInterval(200))
        try discovery.reconcile(files: [f], metadata: .available([f.stem: RecordingMetadata(recordedAt: cutoff.addingTimeInterval(50), deleted: true)]), now: cutoff.addingTimeInterval(210))
        #expect(try store.recording(stem: f.stem)?.state == .canceled)
    }

    @Test func undecidedRecordingIsResolvedWhenMetadataAppearsLater() throws {
        let temp = TempDir("undecided")
        let store = try makeStore(temp)
        let discovery = RecordingDiscovery(store: store, policy: EligibilityPolicy(cutoff: cutoff), stabilityWindow: 0)
        let folder = temp.sub("Recordings")
        let name = SyntheticAudio.voiceMemoName(cutoff.addingTimeInterval(600), suffix: "AAAA0001")
        let f = file(folder, name, bytes: 10, modified: cutoff.addingTimeInterval(700))
        try discovery.reconcile(files: [f], metadata: .unavailable(reason: "locked"), now: cutoff.addingTimeInterval(800))
        #expect(try store.recording(stem: f.stem)?.state == .needsDecision)
        try discovery.reconcile(files: [f], metadata: .available([f.stem: RecordingMetadata(recordedAt: cutoff.addingTimeInterval(600))]), now: cutoff.addingTimeInterval(810))
        let state = try store.recording(stem: f.stem)?.state
        #expect(state == .waitingForSync || state == .preparing)
    }

    // MARK: Voice Memos library (read-only, schema-tolerant)

    func makeLibrary(_ url: URL, columns: String = "ZPATH TEXT, ZUNIQUEID TEXT, ZDATE REAL, ZDURATION REAL, ZENCRYPTEDTITLE TEXT, ZCUSTOMLABEL TEXT, ZEVICTIONDATE REAL",
                     table: String = "ZCLOUDRECORDING") throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: url.path)
        try db.execute("PRAGMA journal_mode=WAL; CREATE TABLE \(table) (Z_PK INTEGER PRIMARY KEY, \(columns));")
        return db
    }

    @Test func libraryIsReadReadOnlyIncludingUncheckpointedWAL() throws {
        let temp = TempDir("library")
        let folder = temp.sub("Recordings")
        let dbURL = folder.appendingPathComponent(VoiceMemosMetadata.databaseName)
        let writer = try makeLibrary(dbURL)
        try writer.execute("PRAGMA wal_autocheckpoint=0")
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try writer.run("INSERT INTO ZCLOUDRECORDING (ZPATH, ZUNIQUEID, ZDATE, ZDURATION, ZENCRYPTEDTITLE, ZCUSTOMLABEL) VALUES (?,?,?,?,?,?)",
                       [.text("20260101 101010-AAAA0001.m4a"), .text("U1"), .double(date.timeIntervalSinceReferenceDate), .double(42), .text("ישיבת צוות"), .text("2026-01-01T10:10:10Z")])
        try writer.run("INSERT INTO ZCLOUDRECORDING (ZPATH, ZDATE, ZCUSTOMLABEL) VALUES (?,?,?)",
                       [.text("Recordings/20260101 111111-AAAA0002.qta"), .double(date.timeIntervalSinceReferenceDate + 60), .text("20260101 111111")])
        try writer.run("INSERT INTO ZCLOUDRECORDING (ZPATH, ZDATE, ZEVICTIONDATE) VALUES (?,?,?)",
                       [.text("20260101 121212-AAAA0003.m4a"), .double(date.timeIntervalSinceReferenceDate + 120), .double(date.timeIntervalSinceReferenceDate + 999)])
        let walSize = (try? FileManager.default.attributesOfItem(atPath: dbURL.path + "-wal")[.size] as? Int) ?? 0
        #expect(walSize > 0, "rows should still be in the WAL")
        let mainBefore = try Data(contentsOf: dbURL)

        let snapshot = VoiceMemosMetadata.load(recordingsFolder: folder)
        guard case .available(let map) = snapshot else { Issue.record("expected metadata, got \(snapshot)"); return }
        #expect(map["20260101 101010-AAAA0001"]?.title == "ישיבת צוות")
        #expect(map["20260101 101010-AAAA0001"]?.recordedAt == date)
        #expect(map["20260101 101010-AAAA0001"]?.uniqueID == "U1")
        #expect(map["20260101 111111-AAAA0002"]?.title == nil, "timestamp-shaped labels are not titles")
        #expect(map["20260101 121212-AAAA0003"]?.deleted == true)
        #expect(try Data(contentsOf: dbURL) == mainBefore, "the library file itself is never modified")
        _ = writer
    }

    @Test func libraryWithAReadOnlyGrantIsReadFromAConsistentCopy() throws {
        let temp = TempDir("library-ro")
        let folder = temp.sub("Recordings")
        let dbURL = folder.appendingPathComponent(VoiceMemosMetadata.databaseName)
        let writer = try makeLibrary(dbURL)
        try writer.execute("PRAGMA wal_autocheckpoint=0")
        try writer.run("INSERT INTO ZCLOUDRECORDING (ZPATH, ZDATE, ZENCRYPTEDTITLE) VALUES (?,?,?)",
                       [.text("20260101 101010-AAAA0001.m4a"), .double(800_000_000), .text("Only in the WAL")])
        // Simulate the read-only grant: nothing in the folder may be written (no -shm updates).
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            chmod(folder.appendingPathComponent(name).path, 0o444)
        }
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let snapshot = VoiceMemosMetadata.load(recordingsFolder: folder)
        #expect(snapshot.lookup("20260101 101010-AAAA0001")?.title == "Only in the WAL")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before, "no files created next to the library")
        _ = writer
    }

    @Test func schemaChangesDegradeToUnavailable() throws {
        let temp = TempDir("schema")
        let a = temp.sub("A"), b = temp.sub("B"), c = temp.sub("C")
        _ = try makeLibrary(a.appendingPathComponent(VoiceMemosMetadata.databaseName), table: "ZSOMETHINGELSE")
        #expect(VoiceMemosMetadata.load(recordingsFolder: a) == .unavailable(reason: "schema-no-table"))
        _ = try makeLibrary(b.appendingPathComponent(VoiceMemosMetadata.databaseName), columns: "ZFILE TEXT, ZDATE REAL")
        #expect(VoiceMemosMetadata.load(recordingsFolder: b) == .unavailable(reason: "schema-no-path"))
        #expect(VoiceMemosMetadata.load(recordingsFolder: c) == .unavailable(reason: "no-database"))
        // Only ZPATH: available, without dates (callers fall back to file names).
        let d = temp.sub("D")
        let db = try makeLibrary(d.appendingPathComponent(VoiceMemosMetadata.databaseName), columns: "ZPATH TEXT")
        try db.run("INSERT INTO ZCLOUDRECORDING (ZPATH) VALUES ('20260101 101010-AAAA0001.m4a')")
        #expect(VoiceMemosMetadata.load(recordingsFolder: d).lookup("20260101 101010-AAAA0001") == RecordingMetadata())
        FileManager.default.createFile(atPath: temp.sub("E").appendingPathComponent(VoiceMemosMetadata.databaseName).path, contents: Data("not a database".utf8))
        #expect(!VoiceMemosMetadata.load(recordingsFolder: temp.url.appendingPathComponent("E")).isAvailable)
    }

    @Test func unrelatedFolderIsNotTakenForRecordings() throws {
        let temp = TempDir("unrelated")
        let unrelated = temp.sub("Music")
        FileManager.default.createFile(atPath: unrelated.appendingPathComponent("song.m4a").path, contents: Data([1]))
        #expect(!VoiceMemosSource.looksLikeRecordingsFolder(unrelated))
        let memos = temp.sub("Memos")
        FileManager.default.createFile(atPath: memos.appendingPathComponent("20261030 101010-AAAA0001.m4a").path, contents: Data([1]))
        #expect(VoiceMemosSource.looksLikeRecordingsFolder(memos))
    }

    @Test func pathProbeTellsDeniedFromMissing() throws {
        let temp = TempDir("probe")
        let locked = temp.sub("Locked")
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o755) }
        #expect(PathProbe.directoryStatus(locked) == .denied)
        #expect(PathProbe.directoryStatus(temp.url.appendingPathComponent("Nope")) == .missing)
        #expect(PathProbe.directoryStatus(temp.url) == .accessible)
    }

    @Test func destinationProposalPrefersPersonalMyDriveThenDocuments() throws {
        let temp = TempDir("locator")
        let home = temp.url
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        #expect(FolderLocator.proposeDestination(home: home).kind == .documents)
        #expect(FolderLocator.proposeDestination(home: home).folder.path.hasSuffix("Documents/Ramble Flow"))

        let cloud = home.appendingPathComponent("Library/CloudStorage")
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("GoogleDrive-work@example.org/My Drive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("GoogleDrive-work@example.org/Shared drives"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("GoogleDrive-someone@gmail.com/My Drive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        let proposal = FolderLocator.proposeDestination(home: home)
        #expect(proposal.kind == .googleDrive)
        #expect(proposal.accountLabel == "someone@gmail.com")
        #expect(proposal.parent.lastPathComponent == "My Drive")
        #expect(proposal.folder.lastPathComponent == "Ramble Flow")
        #expect(proposal.alternatives.count == 1)
        #expect(!proposal.folder.path.contains("Shared drives"))
        // Google Drive's "~/Google Drive" link to the same account is not a second account.
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Google Drive"), withDestinationURL: cloud.appendingPathComponent("GoogleDrive-someone@gmail.com"))
        #expect(FolderLocator.proposeDestination(home: home).alternatives.count == 1)
        // A real mirrored My Drive in the home folder is offered as an alternative.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("My Drive"), withIntermediateDirectories: true)
        #expect(FolderLocator.proposeDestination(home: home).alternatives.count == 2)
        try FileManager.default.removeItem(at: home.appendingPathComponent("My Drive"))
        // Stable across runs.
        #expect(FolderLocator.proposeDestination(home: home) == proposal)
    }

    @Test func driveWithoutResolvableMyDriveIsShownUnresolved() throws {
        let temp = TempDir("locator2")
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("Library/CloudStorage/GoogleDrive-a@example.com"), withIntermediateDirectories: true)
        let proposal = FolderLocator.proposeDestination(home: temp.url)
        #expect(proposal.kind == .googleDrive)
        #expect(proposal.status == .unresolved)
    }

    @Test func sourceDetectionDistinguishesStates() throws {
        let temp = TempDir("source")
        #expect(FolderLocator.detectSource(home: temp.url).status == .notFound)
        let recordings = temp.url.appendingPathComponent(VoiceMemosSource.knownLocations[0])
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        #expect(FolderLocator.detectSource(home: temp.url).status == .ready)
        chmod(recordings.path, 0o000)
        defer { chmod(recordings.path, 0o755) }
        #expect(FolderLocator.detectSource(home: temp.url).status == .needsAccess)
    }
}
