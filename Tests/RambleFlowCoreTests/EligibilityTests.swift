import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Eligibility: new recordings only")
struct EligibilityTests {
    let cutoff = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed instant
    var policy: EligibilityPolicy { EligibilityPolicy(cutoff: cutoff) }

    func wall(_ date: Date, in zone: TimeZone) -> FileNameDate.WallClock {
        let name = SyntheticAudio.voiceMemoName(date, suffix: "ABCDEF12", timeZone: zone)
        return FileNameDate.parse(name)!
    }

    @Test func archivePresentAtActivationIsExcluded() {
        let decision = policy.decide(.init(inBaseline: true, metadataDate: cutoff.addingTimeInterval(3600)))
        #expect(decision == .excluded(reason: "present-at-activation"))
    }

    @Test func lateArrivingOldMemoIsExcludedByLibraryDate() {
        // Recorded a day before setup, delivered by iCloud a day after (fresh mtime).
        let decision = policy.decide(.init(inBaseline: false, metadataDate: cutoff.addingTimeInterval(-86_400), modified: cutoff.addingTimeInterval(86_400)))
        #expect(decision == .excluded(reason: "recorded-before-cutoff"))
    }

    @Test func lateArrivingOldMemoIsExcludedByPreservedModificationTime() {
        // No library metadata, ambiguous file-name date, but the preserved mtime predates the cutoff.
        let decision = policy.decide(.init(inBaseline: false, fileNameWallClock: wall(cutoff.addingTimeInterval(-600), in: .current), modified: cutoff.addingTimeInterval(-300)))
        #expect(decision == .excluded(reason: "modified-before-cutoff"))
    }

    @Test func newMemoRecordedWhileAsleepIsEligibleLater() {
        // Recorded 3 hours after the cutoff while the Mac slept; scanned 8 hours later.
        let decision = policy.decide(.init(inBaseline: false, metadataDate: cutoff.addingTimeInterval(3 * 3600), modified: cutoff.addingTimeInterval(8 * 3600)))
        #expect(decision == .eligible)
    }

    @Test func modificationTimeAloneNeverMakesARecordingNew() {
        let decision = policy.decide(.init(inBaseline: false, modified: cutoff.addingTimeInterval(3600)))
        #expect(decision == .undetermined(reason: "no-recording-date"))
    }

    @Test func fileNameDateNearTheCutoffWaitsForADecision() {
        let decision = policy.decide(.init(inBaseline: false, fileNameWallClock: wall(cutoff.addingTimeInterval(1800), in: .current), modified: cutoff.addingTimeInterval(2000)))
        #expect(decision == .undetermined(reason: "file-name-date-near-cutoff"))
    }

    @Test func fileNameDateFarFromTheCutoffIsDecidedInAnyTimeZone() {
        for zone in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Jerusalem", "America/New_York"].compactMap(TimeZone.init(identifier:)) {
            let newer = policy.decide(.init(inBaseline: false, fileNameWallClock: wall(cutoff.addingTimeInterval(30 * 3600), in: zone), modified: cutoff.addingTimeInterval(31 * 3600)))
            #expect(newer == .eligible, "zone \(zone.identifier)")
            let older = policy.decide(.init(inBaseline: false, fileNameWallClock: wall(cutoff.addingTimeInterval(-30 * 3600), in: zone)))
            #expect(older == .excluded(reason: "recorded-before-cutoff"), "zone \(zone.identifier)")
        }
    }

    @Test func deletedInVoiceMemosIsExcluded() {
        #expect(policy.decide(.init(inBaseline: false, metadataDate: cutoff.addingTimeInterval(60), deletedInVoiceMemos: true)) == .excluded(reason: "deleted-in-voice-memos"))
    }

    @Test func malformedFileNamesAreRejected() {
        #expect(FileNameDate.parse("20260230 101010-ABCDEF12.m4a") == nil)   // Feb 30
        #expect(FileNameDate.parse("20261030 251010-ABCDEF12.m4a") == nil)   // hour 25
        #expect(FileNameDate.parse("20261030 106110-ABCDEF12.m4a") == nil)   // minute 61
        #expect(FileNameDate.parse("Meeting notes.m4a") == nil)
        #expect(FileNameDate.parse("2026103 101010-ABCDEF12.m4a") == nil)
        #expect(FileNameDate.parse("19991030 101010-ABCDEF12.m4a") == nil)
        #expect(FileNameDate.parse("20261030 101010-ABCDEF12.m4a") == FileNameDate.WallClock(year: 2026, month: 10, day: 30, hour: 10, minute: 10, second: 10))
        #expect(FileNameDate.parse("20261030_101010.qta") != nil)
    }

    @Test func daylightSavingGapAndOverlapResolveDeterministically() {
        let zone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 02:30 does not exist in New York (spring forward).
        let gap = FileNameDate.WallClock(year: 2026, month: 3, day: 8, hour: 2, minute: 30, second: 0)
        let gapInstant = FileNameDate.instant(gap, in: zone)
        #expect(abs(gapInstant.timeIntervalSince(FileNameDate.asUTC(gap)) - 4 * 3600) <= 3600)
        // 2026-11-01 01:30 happens twice (fall back); the result is one of the two, consistently.
        let overlap = FileNameDate.WallClock(year: 2026, month: 11, day: 1, hour: 1, minute: 30, second: 0)
        #expect(FileNameDate.instant(overlap, in: zone) == FileNameDate.instant(overlap, in: zone))
    }

    @Test func cutoffSurvivesRestartPauseAndRepeatedActivation() throws {
        let temp = TempDir("cutoff")
        let url = temp.url.appendingPathComponent("jobs.sqlite")
        let first = try JobStore(url: url).activate(cutoff: cutoff, baselineStems: ["a", "b"], now: cutoff)
        // A later activation (update, permission repair) must not move it.
        let second = try JobStore(url: url).activate(cutoff: cutoff.addingTimeInterval(86_400), baselineStems: ["c"], now: cutoff.addingTimeInterval(86_400))
        #expect(first == second)
        let reopened = try JobStore(url: url)
        #expect(try reopened.activation()?.cutoff == cutoff)
        #expect(try reopened.isInBaseline("a"))
        #expect(try !reopened.isInBaseline("c"))
        let config = ConfigStore(url: temp.url.appendingPathComponent("config.json"))
        try config.update { $0.paused = true }
        try config.update { $0.paused = false }
        #expect(try JobStore(url: url).activation()?.cutoff == cutoff)
    }
}
