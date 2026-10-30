import Foundation

/// Removes anything that looks like a credential from text that may reach a log, an error message
/// or the UI. Provider error bodies can echo part of a key ("Incorrect API key provided: sk-...").
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        // OpenAI style (sk-, sk-proj-), Groq style (gsk_), generic bearer tokens.
        try! NSRegularExpression(pattern: #"(?i)\b(sk|gsk|rk|pk)[-_][A-Za-z0-9_\-\*\.]{6,}"#),
        try! NSRegularExpression(pattern: #"(?i)bearer\s+[A-Za-z0-9_\-\.=]+"#),
        try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_\-]{32,}\b"#),
    ]

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted]")
        }
        return result
    }

    /// Masked display of a key: first characters of its prefix, bullets, last four.
    public static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return String(repeating: "•", count: max(4, trimmed.count)) }
        var prefix = ""
        for candidate in ["sk-proj-", "gsk_", "sk-"] where trimmed.hasPrefix(candidate) {
            prefix = candidate
            break
        }
        return prefix + String(repeating: "•", count: 8) + String(trimmed.suffix(4))
    }
}

/// Small rotating text log (`~/Library/Logs/Ramble Flow CLI/ramble-flow.log`).
///
/// It records app/build/OS versions, generic states, HTTP statuses and timings. Callers pass
/// recording references (a short hash), never titles, transcript text, paths with names, emails
/// or keys; every line is passed through `Redactor` as a last line of defense.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "ramble-flow.log")
    private var fileURL: URL?
    private let maxBytes = 512 * 1024
    private let keepFiles = 3
    public var echoToStderr = false

    public func configure(directory: URL) {
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("ramble-flow.log")
        }
    }

    /// Waits until queued lines are on disk.
    public func flush() { queue.sync {} }

    public func info(_ message: String) { write("INFO", message) }
    public func warn(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(Redactor.redact(message))\n"
        if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        queue.async { [self] in
            guard let fileURL else { return }
            rotateIfNeeded(fileURL)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    private func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        let fm = FileManager.default
        for index in stride(from: keepFiles - 1, through: 1, by: -1) {
            let older = url.appendingPathExtension("\(index)")
            let newer = index == 1 ? url : url.appendingPathExtension("\(index - 1)")
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: newer, to: older)
        }
    }
}
