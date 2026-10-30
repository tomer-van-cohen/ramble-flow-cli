import CryptoKit
import Foundation

public enum Hashing {
    /// SHA-256 of a file, read in 1 MB pieces so a multi-hour recording never sits in memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Short, stable, non-reversible reference for a recording (used in file names and logs).
    public static func shortReference(for identity: String) -> String {
        String(sha256(identity).prefix(8))
    }
}
