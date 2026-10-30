import Foundation

/// A recording file as seen in the source folder.
public struct SourceFile: Sendable, Equatable {
    public var url: URL
    public var fileName: String
    public var stem: String
    public var size: Int64
    public var modified: Date

    public init(url: URL, size: Int64, modified: Date) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.stem = url.deletingPathExtension().lastPathComponent
        self.size = size
        self.modified = modified
    }
}

/// Adapter for Apple's Voice Memos storage. The location is an internal Apple layout, not a public
/// API, so everything layout-specific lives here.
public enum VoiceMemosSource {
    /// Relative to the real home folder, newest layout first.
    public static let knownLocations: [String] = [
        "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
        // Layout used before Voice Memos moved into a group container.
        "Library/Application Support/com.apple.voicememos/Recordings",
    ]

    public static let audioExtensions: Set<String> = ["qta", "m4a"]

    public static func candidates(home: URL = RealHome.url) -> [URL] {
        knownLocations.map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// Lists top-level recording files. Waveform files, hidden/temporary files, iCloud placeholders,
    /// capture folders and other formats are ignored. Zero-byte files are reported (they are
    /// placeholders still downloading) so discovery can wait on them.
    public static func listRecordings(in folder: URL) throws -> [SourceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        var files: [SourceFile] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(".icloud") || name.hasSuffix(".tmp") { continue }
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(SourceFile(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.fileName < $1.fileName }
    }

    /// Whether a user-chosen folder plausibly holds Voice Memos recordings. Used to refuse an unrelated
    /// folder picked by mistake, so nothing uploads from it.
    public static func looksLikeRecordingsFolder(_ folder: URL) -> Bool {
        if candidates().contains(where: { $0.standardizedFileURL.path == folder.standardizedFileURL.path }) { return true }
        if folder.lastPathComponent == "Recordings" && folder.path.contains("VoiceMemos") { return true }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(VoiceMemosMetadata.databaseName).path) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        return names.contains { name in
            audioExtensions.contains((name as NSString).pathExtension.lowercased()) && FileNameDate.parse(name) != nil
        }
    }
}

/// "20261030 125048-1A2B3C4D.m4a" → wall-clock 2026-10-30 12:50:48 (time zone of the recording device,
/// which the file name does not say).
public enum FileNameDate {
    public struct WallClock: Equatable, Sendable {
        public var year, month, day, hour, minute, second: Int
    }

    public static func parse(_ name: String) -> WallClock? {
        let pattern = #"^(\d{4})(\d{2})(\d{2})[ _-](\d{2})(\d{2})(\d{2})(?:[-_ ]|\.|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
        func group(_ i: Int) -> Int? {
            guard let range = Range(match.range(at: i), in: name) else { return nil }
            return Int(name[range])
        }
        guard let y = group(1), let mo = group(2), let d = group(3), let h = group(4), let mi = group(5), let s = group(6) else { return nil }
        guard (2000...2100).contains(y), (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else { return nil }
        // Reject impossible calendar dates (Feb 30 etc.).
        var components = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: min(s, 59))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        components.timeZone = calendar.timeZone
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == d, calendar.component(.month, from: date) == mo else { return nil }
        return WallClock(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    /// The wall clock read as if it were UTC. Real instants lie within [-14h, +12h] of this.
    public static func asUTC(_ wall: WallClock) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: wall.year, month: wall.month, day: wall.day, hour: wall.hour, minute: wall.minute, second: min(wall.second, 59)))!
    }

    /// Best guess for display: the wall clock in the given zone (the Mac's). In a DST gap the
    /// calendar moves the time forward; in an overlap it picks the first occurrence.
    public static func instant(_ wall: WallClock, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: wall.year, month: wall.month, day: wall.day, hour: wall.hour, minute: wall.minute, second: min(wall.second, 59))
        return calendar.date(from: components) ?? asUTC(wall)
    }
}
