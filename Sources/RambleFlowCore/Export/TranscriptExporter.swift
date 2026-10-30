import Darwin
import Foundation

/// The readable file Ramble Flow writes for each recording.
public struct TranscriptDocument: Sendable, Equatable {
    public var title: String?
    public var recordedAt: Date?
    public var dateConfidence: DateConfidence
    public var duration: TimeInterval?
    public var providerName: String
    public var model: String
    public var reference: String
    public var text: String
    public var noSpeech: Bool

    public init(title: String?, recordedAt: Date?, dateConfidence: DateConfidence, duration: TimeInterval?, providerName: String, model: String, reference: String, text: String, noSpeech: Bool) {
        self.title = title
        self.recordedAt = recordedAt
        self.dateConfidence = dateConfidence
        self.duration = duration
        self.providerName = providerName
        self.model = model
        self.reference = reference
        self.text = text
        self.noSpeech = noSpeech
    }

    public static let genericTitle = "Voice memo"

    /// Plain UTF-8 text: a short searchable header, a blank line, then the transcript as spoken.
    public func rendered(timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        lines.append("Title: \(TranscriptNaming.cleanTitle(title) ?? Self.genericTitle)")
        if let recordedAt {
            var line = "Recorded: \(TranscriptNaming.isoWithOffset(recordedAt, timeZone: timeZone))"
            if dateConfidence == .fileName { line += " (time zone assumed)" }
            lines.append(line)
        }
        if let duration { lines.append("Duration: \(TranscriptNaming.clock(duration))") }
        lines.append("Transcribed with: \(providerName) / \(model)")
        lines.append("Recording ID: \(reference)")
        lines.append("")
        lines.append(noSpeech || text.isEmpty ? "[No speech detected]" : text)
        return lines.joined(separator: "\n") + "\n"
    }
}

public enum TranscriptNaming {
    /// Bytes allowed for the title part of a file name (names are limited to 255 bytes).
    public static let maxTitleBytes = 120

    /// "2026-10-30 12-50-48 — Meeting notes — a1b2c3d4.txt"
    public static func fileName(recordedAt: Date?, title: String?, reference: String, timeZone: TimeZone = .current, collision: Int = 0) -> String {
        var parts: [String] = []
        if let recordedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
            parts.append(formatter.string(from: recordedAt))
        }
        parts.append(cleanTitle(title).map { truncate($0, maxBytes: maxTitleBytes) } ?? TranscriptDocument.genericTitle)
        parts.append(reference)
        var name = parts.joined(separator: " — ")
        if collision > 0 { name += " (\(collision + 1))" }
        return name + ".txt"
    }

    /// NFC-normalized, single-line, no path separators or control characters, no leading dots.
    /// Hebrew and other scripts are kept as they are; bidi control characters are removed so a
    /// name cannot visually reorder its date or extension.
    public static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in title.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: scalars.append(" ")
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: continue
            case 0x2F, 0x5C, 0x3A: scalars.append("-")   // / \ :
            default: scalars.append(scalar)
            }
        }
        var cleaned = String(scalars)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func truncate(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        for character in string {
            if result.utf8.count + String(character).utf8.count > maxBytes - 3 { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func isoWithOffset(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

public enum ExportError: Error, Equatable {
    /// The folder is gone (unmounted Drive, deleted folder).
    case destinationMissing
    /// Permission to write was lost.
    case destinationDenied
    case writeFailed(Int32)
}

/// Writes transcript files idempotently and atomically.
///
/// Each recording reserves a name once. The text is written to a hidden temporary file in the same
/// folder and moved into place with an exclusive rename, which fails instead of replacing anything.
/// If the reserved name exists and holds exactly our text, an earlier attempt already succeeded
/// (crash between rename and database commit). Any other existing file is the user's: it is never
/// overwritten, and the next free name is used instead.
public struct TranscriptExporter {
    public init() {}

    public struct Result: Equatable {
        public var fileName: String
        public var contentHash: String
        public var alreadyPresent: Bool
    }

    public func export(_ contents: String, preferredName: (Int) -> String, reservedName: String?, into folder: URL) throws -> Result {
        guard PathProbe.exists(folder) else { throw ExportError.destinationMissing }
        guard PathProbe.isDirectory(folder) else { throw ExportError.destinationMissing }
        let data = Data(contents.utf8)
        let hash = Hashing.sha256(contents)

        var candidates: [String] = []
        if let reservedName { candidates.append(reservedName) }
        for collision in 0..<50 {
            let name = preferredName(collision)
            if !candidates.contains(name) { candidates.append(name) }
        }

        let temporary = folder.appendingPathComponent(".ramble-flow-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
        } catch {
            throw Self.classify(error)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        for name in candidates {
            let target = folder.appendingPathComponent(name)
            if PathProbe.exists(target) {
                if let existing = try? Data(contentsOf: target), Hashing.sha256(String(decoding: existing, as: UTF8.self)) == hash {
                    return Result(fileName: name, contentHash: hash, alreadyPresent: true)
                }
                continue   // someone else's file (or a transcript the user edited): never replace it
            }
            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return Result(fileName: name, contentHash: hash, alreadyPresent: false)
            }
            let code = errno
            if code == EEXIST { continue }
            if code == ENOTSUP || code == EINVAL {
                // Some file systems do not support exclusive rename. Fall back to a hard link,
                // which also refuses to replace an existing name.
                if link(temporary.path, target.path) == 0 {
                    return Result(fileName: name, contentHash: hash, alreadyPresent: false)
                }
                if errno == EEXIST { continue }
                // Last resort: write directly without overwriting.
                do {
                    try data.write(to: target, options: [.withoutOverwriting])
                    return Result(fileName: name, contentHash: hash, alreadyPresent: false)
                } catch {
                    if PathProbe.exists(target) { continue }
                    throw Self.classify(error)
                }
            }
            throw code == EACCES || code == EPERM ? ExportError.destinationDenied : ExportError.writeFailed(code)
        }
        throw ExportError.writeFailed(EEXIST)
    }

    static func classify(_ error: Error) -> ExportError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .destinationDenied
            case NSFileNoSuchFileError, NSFileWriteVolumeReadOnlyError: return .destinationMissing
            default: break
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                if underlying.code == Int(EACCES) || underlying.code == Int(EPERM) { return .destinationDenied }
                if underlying.code == Int(ENOENT) { return .destinationMissing }
                return .writeFailed(Int32(underlying.code))
            }
        }
        return .writeFailed(Int32(ns.code))
    }
}
