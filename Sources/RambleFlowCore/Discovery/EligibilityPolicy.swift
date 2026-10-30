import Foundation

/// Decides whether a recording is "new" (made at or after the activation cutoff).
///
/// "New only" is about when the recording was made, not when its file appeared on this Mac or when
/// it was last modified. Old recordings that iCloud delivers late must stay excluded; recordings
/// made while the Mac slept, the app was closed or offline stay eligible.
public struct EligibilityPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case eligible
        case excluded(reason: String)
        /// The age cannot be established safely; wait for a decision, never upload silently.
        case undetermined(reason: String)
    }

    /// The file name carries local wall-clock time of the recording device. Real UTC offsets lie in
    /// [-12h, +14h], so the true instant is within this window around the wall clock read as UTC.
    public static let earliestOffset: TimeInterval = -14 * 3600
    public static let latestOffset: TimeInterval = 12 * 3600

    public var cutoff: Date

    public init(cutoff: Date) {
        self.cutoff = cutoff
    }

    public struct Evidence: Sendable {
        public var inBaseline: Bool
        public var metadataDate: Date?
        public var fileNameWallClock: FileNameDate.WallClock?
        /// File modification time on this Mac. It is never before the recording ended (it is either
        /// preserved from the recording device or later, when the file arrived), so it can prove a
        /// recording is OLD, but never that it is new.
        public var modified: Date?
        public var deletedInVoiceMemos: Bool

        public init(inBaseline: Bool, metadataDate: Date? = nil, fileNameWallClock: FileNameDate.WallClock? = nil, modified: Date? = nil, deletedInVoiceMemos: Bool = false) {
            self.inBaseline = inBaseline
            self.metadataDate = metadataDate
            self.fileNameWallClock = fileNameWallClock
            self.modified = modified
            self.deletedInVoiceMemos = deletedInVoiceMemos
        }
    }

    public func decide(_ e: Evidence) -> Decision {
        if e.inBaseline { return .excluded(reason: "present-at-activation") }
        if e.deletedInVoiceMemos { return .excluded(reason: "deleted-in-voice-memos") }
        if let modified = e.modified, modified < cutoff {
            return .excluded(reason: "modified-before-cutoff")
        }
        if let date = e.metadataDate {
            return date >= cutoff ? .eligible : .excluded(reason: "recorded-before-cutoff")
        }
        if let wall = e.fileNameWallClock {
            let asUTC = FileNameDate.asUTC(wall)
            let earliest = asUTC.addingTimeInterval(Self.earliestOffset)
            let latest = asUTC.addingTimeInterval(Self.latestOffset)
            if earliest >= cutoff { return .eligible }
            if latest < cutoff { return .excluded(reason: "recorded-before-cutoff") }
            return .undetermined(reason: "file-name-date-near-cutoff")
        }
        return .undetermined(reason: "no-recording-date")
    }
}
