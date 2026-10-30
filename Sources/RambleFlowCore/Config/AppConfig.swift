import Darwin
import Foundation

/// Settings written by the installer and read by the background process, stored as JSON in the
/// private support folder. API keys are not here (`secrets.env`); job state is not here (SQLite).
public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = AppConfig.currentVersion
    public var provider: ProviderID = .groq
    /// Nil means the provider's default model.
    public var model: String?
    /// Optional ISO-639-1 hint. Nil means automatic language detection (the default).
    public var languageHint: String?
    /// The Voice Memos recordings folder (absolute path).
    public var sourcePath: String?
    /// The transcripts folder (absolute path, normally ending in "Ramble Flow").
    public var destinationPath: String?
    public var paused = false
    /// Set by the installer once settings are complete; the background process does nothing before.
    public var setupCompleted = false

    public init() {}

    public var effectiveModel: String {
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty { return model }
        return provider.defaultModel
    }

    enum CodingKeys: String, CodingKey {
        case version, provider, model, languageHint, sourcePath, destinationPath, paused, setupCompleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        provider = try c.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .groq
        model = try c.decodeIfPresent(String.self, forKey: .model)
        languageHint = try c.decodeIfPresent(String.self, forKey: .languageHint)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? false
    }
}

/// Atomic JSON persistence for `AppConfig`. Another process (the installer, `ramble-flow pause`)
/// may rewrite the file while the background process runs, so `current` re-reads it when it
/// changed (checked at most once per second).
public final class ConfigStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached: AppConfig
    private var stamp: String = ""
    private var lastCheck = Date.distantPast

    public init(url: URL) {
        self.url = url
        cached = AppConfig()
        reloadLocked(force: true)
    }

    public var exists: Bool { PathProbe.exists(url) }

    public var current: AppConfig {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastCheck) >= 1 { reloadLocked(force: false) }
        return cached
    }

    /// Re-reads the file now if it changed.
    public func reload() {
        lock.lock()
        reloadLocked(force: false)
        lock.unlock()
    }

    private func fileStamp() -> String {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return "absent" }
        return "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)-\(info.st_ino)"
    }

    private func reloadLocked(force: Bool) {
        lastCheck = Date()
        let current = fileStamp()
        guard force || current != stamp else { return }
        stamp = current
        if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cached = config
        } else if current == "absent" {
            cached = AppConfig()
        }
        // A file that exists but cannot be decoded keeps the last good settings.
    }

    @discardableResult
    public func update(_ change: (inout AppConfig) -> Void) throws -> AppConfig {
        lock.lock()
        defer { lock.unlock() }
        reloadLocked(force: true)
        var next = cached
        change(&next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(next).write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
        cached = next
        stamp = fileStamp()
        return next
    }
}
