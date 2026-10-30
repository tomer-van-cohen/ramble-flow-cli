import Foundation

/// What the app tells the user about background work. "Watching" with nothing to do is healthy.
public struct WorkerStatus: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case notActivated
        case paused
        case needsKey
        /// The key file exists but could not be read.
        case credentialsUnreadable
        case needsSourceAccess
        case needsDestinationAccess
        case outputUnavailable
        case transcribing
        case waitingForInternet
        case waitingForProviderLimit
        case needsAttention
        case watching
    }

    public var phase: Phase
    /// Recordings on their way to a transcript.
    public var pending: Int
    /// Recordings that need the user (failed, unknown outcome, unsupported audio, quota, configuration).
    public var attention: Int
    /// Recordings whose age could not be determined.
    public var undecided: Int
    public var lastExportedName: String?
    public var lastExportedAt: Date?
    /// Machine reason for the phase, e.g. "quota", "destination-missing".
    public var detail: String?

    public init(phase: Phase, pending: Int = 0, attention: Int = 0, undecided: Int = 0, lastExportedName: String? = nil, lastExportedAt: Date? = nil, detail: String? = nil) {
        self.phase = phase
        self.pending = pending
        self.attention = attention
        self.undecided = undecided
        self.lastExportedName = lastExportedName
        self.lastExportedAt = lastExportedAt
        self.detail = detail
    }
}

public struct WorkerSettings: Sendable {
    public var stabilityWindow: TimeInterval = 15
    public var missingGrace: TimeInterval = 60
    /// Uncertain outcomes (timeouts after sending) tolerated before asking the user.
    public var maxUncertainAttempts = 3
    /// App-private working files above this size pause new snapshots.
    public var maxWorkBytes: Int64 = 2_000_000_000
    /// Cached transcript text of exported recordings is dropped after this long.
    public var transcriptRetention: TimeInterval = 7 * 24 * 3600
    public var maxBackoff: TimeInterval = 30 * 60
    public var offlineMaxBackoff: TimeInterval = 5 * 60
    public var quotaRetry: TimeInterval = 60 * 60
    public var minimumSplitDuration: TimeInterval = 20

    public init() {}
}

public enum FolderAvailability: Sendable {
    case available(FolderAccess)
    /// Not configured, not permitted ("denied") or not there ("missing").
    case notGranted(String)
}
