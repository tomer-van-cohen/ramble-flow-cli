import Foundation

// MARK: - Providers

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case groq
    case openai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    /// Defaults checked against the official docs on 2026-10-30 (see docs/PROVIDERS.md).
    public var defaultModel: String {
        switch self {
        case .groq: return "whisper-large-v3"
        case .openai: return "gpt-transcribe"
        }
    }

    /// Name of the line in `secrets.env`, and of the environment variable that overrides it.
    public var environmentVariable: String {
        switch self {
        case .groq: return "GROQ_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        }
    }

    /// Other transcription models the provider documents (checked 2026-10-30). Any model id is
    /// accepted; an unsupported one is reported as a configuration problem, never swapped silently.
    public var otherModels: [String] {
        switch self {
        case .groq: return ["whisper-large-v3-turbo"]
        case .openai: return []
        }
    }

    public var keyConsoleURL: URL {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    public var limitsURL: URL {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/docs/rate-limits")!
        case .openai: return URL(string: "https://platform.openai.com/docs/guides/rate-limits")!
        }
    }
}

/// What a provider accepts. Adapters own these numbers; the chunk planner obeys them.
public struct ProviderCapabilities: Sendable, Equatable {
    /// The documented hard cap for one upload.
    public var maxUploadBytes: Int
    /// What the planner aims for, leaving headroom below the cap (multipart overhead, encoder drift).
    public var targetUploadBytes: Int
    /// Longest audio sent in one request.
    public var maxChunkDuration: TimeInterval
    public var acceptedExtensions: Set<String>

    public init(maxUploadBytes: Int, targetUploadBytes: Int, maxChunkDuration: TimeInterval, acceptedExtensions: Set<String>) {
        self.maxUploadBytes = maxUploadBytes
        self.targetUploadBytes = targetUploadBytes
        self.maxChunkDuration = maxChunkDuration
        self.acceptedExtensions = acceptedExtensions
    }
}

// MARK: - Recording dates

/// How sure we are about when a recording was made.
public enum DateConfidence: String, Codable, Sendable {
    /// From the Voice Memos library (an absolute instant).
    case metadata
    /// From the file name's local wall-clock time; the time zone of the recording device is unknown.
    case fileName
    /// No reliable recording date.
    case unknown
}

// MARK: - Job states

/// Durable state of one recording. The happy path is
/// `discovered → waitingForSync → preparing → queued → transcribing → readyToExport → exported`.
public enum JobState: String, Codable, Sendable, CaseIterable {
    // Discovery
    case discovered
    case waitingForSync
    /// Present before activation, or recorded before the cutoff. Never uploaded.
    case excluded
    /// The recording's age could not be established; it waits for a decision instead of uploading.
    case needsDecision

    // Pipeline
    case preparing
    case queued
    case transcribing
    case readyToExport
    case exported

    // Waiting / attention
    case retryScheduled
    case needsCredentials
    case needsFolderAccess
    case needsAttention
    case providerOutcomeUnknown
    case unsupportedAudio
    case sourceChanged
    case canceled

    /// States in which provider work for the current generation may be underway or pending.
    public var isActive: Bool {
        switch self {
        case .preparing, .queued, .transcribing, .readyToExport, .retryScheduled, .needsCredentials,
             .needsFolderAccess, .sourceChanged:
            return true
        default:
            return false
        }
    }

    /// Terminal from the pipeline's point of view.
    public var isTerminal: Bool {
        switch self {
        case .excluded, .exported, .canceled: return true
        default: return false
        }
    }
}

public enum ChunkStatus: String, Codable, Sendable {
    case pending
    case done
}

/// One planned slice of a recording's audio.
public struct ChunkSpan: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end - start }
}
