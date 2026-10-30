import Darwin
import Foundation

public enum CredentialError: Error, Equatable {
    /// The key file exists but cannot be read right now. Not the same as "no key".
    case unreadable(Int32)
    case writeFailed(Int32)
}

public protocol CredentialStore: Sendable {
    /// Nil when no key is available. Throws when the store cannot be read right now.
    func key(for provider: ProviderID) throws -> String?
    func setKey(_ key: String, for provider: ProviderID) throws
    func removeKey(for provider: ProviderID) throws
}

/// API keys in a private env-style file, `secrets.env`:
///
///     GROQ_API_KEY=gsk_…
///     OPENAI_API_KEY=sk-…
///
/// The file is plaintext, created with mode 0600 inside a 0700 folder, so only the user's own
/// account (and root) can read it. It never lives in the repository or the transcripts folder and
/// its contents are never logged. No macOS Keychain is involved, so no system prompt can ever
/// appear, before or after a rebuild.
///
/// An environment variable with the same name (`GROQ_API_KEY`, `OPENAI_API_KEY`) overrides the
/// file when it is set and not empty.
public struct KeyFileStore: CredentialStore {
    public let url: URL
    public let environment: [String: String]

    public init(url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.url = url
        self.environment = environment
    }

    public static let header = """
    # Ramble Flow API keys. Written by ./install.sh. Plaintext, readable only by your
    # user account (mode 0600). Never commit, share or copy this file.
    """

    public func key(for provider: ProviderID) throws -> String? {
        if let value = environment[provider.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return try fileKey(for: provider)
    }

    /// The key stored in the file only (ignoring the environment).
    public func fileKey(for provider: ProviderID) throws -> String? {
        let values = try read()
        guard let value = values[provider.environmentVariable], !value.isEmpty else { return nil }
        return value
    }

    /// Whether the environment currently overrides the file for this provider.
    public func environmentOverrides(_ provider: ProviderID) -> Bool {
        !(environment[provider.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public func setKey(_ key: String, for provider: ProviderID) throws {
        var values = try read()
        values[provider.environmentVariable] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(values)
    }

    public func removeKey(for provider: ProviderID) throws {
        var values = try read()
        values[provider.environmentVariable] = nil
        if values.isEmpty {
            if unlink(url.path) != 0 && errno != ENOENT { throw CredentialError.writeFailed(errno) }
        } else {
            try write(values)
        }
    }

    /// The file's permission bits, or nil when it does not exist.
    public func permissions() -> mode_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    // MARK: File format

    func read() throws -> [String: String] {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw CredentialError.unreadable(errno)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data: Data?
        do { data = try handle.readToEnd() } catch { throw CredentialError.unreadable(EIO) }
        return Self.parse(String(decoding: data ?? Data(), as: UTF8.self))
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            values[name] = value
        }
        return values
    }

    /// Atomic and private from the first byte: written to a 0600 temporary file in the same
    /// folder, then renamed over the old one.
    func write(_ values: [String: String]) throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var text = Self.header + "\n"
        for name in values.keys.sorted() {
            let value = values[name]!
            guard !value.contains(where: \.isNewline) else { continue }
            text += "\(name)=\(value)\n"
        }
        let temporary = directory.appendingPathComponent(".secrets-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CredentialError.writeFailed(errno) }
        fchmod(fd, 0o600)
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let syncResult = fsync(fd)
        close(fd)
        guard written == bytes.count, syncResult == 0 else {
            unlink(temporary.path)
            throw CredentialError.writeFailed(EIO)
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            unlink(temporary.path)
            throw CredentialError.writeFailed(code)
        }
    }
}

/// In-memory credentials for tests.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [ProviderID: String] = [:]
    private let lock = NSLock()
    public var failure: CredentialError?

    public init(_ keys: [ProviderID: String] = [:]) {
        self.keys = keys
    }

    public func key(for provider: ProviderID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        return keys[provider]
    }

    public func setKey(_ key: String, for provider: ProviderID) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        keys[provider] = key
    }

    public func removeKey(for provider: ProviderID) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[provider] = nil
    }
}
