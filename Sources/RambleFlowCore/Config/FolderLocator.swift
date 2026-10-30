import Foundation

/// Where recordings are, as far as this process can tell.
public struct SourceDetection: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        /// The folder exists and can be read now.
        case ready
        /// The folder exists, but macOS refuses to list it for this process (Full Disk Access).
        case needsAccess
        /// No known Voice Memos folder exists (Voice Memos/iCloud may need enabling).
        case notFound
        /// Something exists at the expected place but is not a folder of recordings.
        case unsupportedLayout
    }

    public var url: URL
    public var status: Status
}

/// Where transcripts should go by default.
public struct DestinationProposal: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case googleDrive
        case documents
    }

    public enum Status: String, Equatable, Sendable {
        /// The parent exists.
        case proposed
        /// Google Drive is present, but its My Drive folder could not be resolved without access.
        case unresolved
    }

    public var kind: Kind
    /// My Drive, or Documents.
    public var parent: URL
    /// `parent/Ramble Flow`.
    public var folder: URL
    public var status: Status
    /// Account context for a Drive proposal ("someone@example.com"), shown so the user can tell
    /// accounts apart.
    public var accountLabel: String?
    /// Other usable Drive roots.
    public var alternatives: [URL]
    /// Whether the Google Drive folder list could be read at all.
    public var driveDiscovery: DriveDiscovery

    public enum DriveDiscovery: String, Equatable, Sendable {
        case found
        case none
        case notPermitted
    }
}

public enum FolderLocator {
    public static let destinationFolderName = "Ramble Flow"

    /// Localized names Google Drive for desktop uses for the "My Drive" root. Detection never relies
    /// on reading Google's private files.
    public static let myDriveNames = ["My Drive", "Meine Ablage", "Mon Drive", "Mi unidad", "Il mio Drive", "Minha unidade", "Mijn Drive", "マイドライブ", "내 드라이브", "我的云端硬盘", "האחסון שלי"]

    public static func detectSource(home: URL = RealHome.url) -> SourceDetection {
        let candidates = VoiceMemosSource.candidates(home: home)
        var firstDenied: URL?
        for url in candidates {
            switch PathProbe.directoryStatus(url) {
            case .accessible: return SourceDetection(url: url, status: .ready)
            case .denied: if firstDenied == nil { firstDenied = url }
            case .notDirectory: return SourceDetection(url: url, status: .unsupportedLayout)
            case .missing: continue
            }
        }
        if let firstDenied { return SourceDetection(url: firstDenied, status: .needsAccess) }
        return SourceDetection(url: candidates[0], status: .notFound)
    }

    /// Proposes Google Drive's My Drive first, Documents otherwise.
    ///
    /// Lists `~/Library/CloudStorage` to see which Google Drive accounts exist, and checks known
    /// My Drive names with `stat` (never listing inside the Drive, which can trigger macOS's File
    /// Provider consent prompt). Shared drives are never proposed. Personal accounts
    /// (gmail.com/googlemail.com) are preferred, then the alphabetically first, so the proposal is
    /// stable from run to run.
    public static func proposeDestination(home: URL = RealHome.url) -> DestinationProposal {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)

        var discovery: DestinationProposal.DriveDiscovery = .none
        var roots: [(account: String, root: URL, myDrive: URL?)] = []
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)
            for name in names.sorted() where name.hasPrefix("GoogleDrive-") {
                let root = cloudStorage.appendingPathComponent(name, isDirectory: true)
                let account = String(name.dropFirst("GoogleDrive-".count))
                let myDrive = myDriveNames.lazy.map { root.appendingPathComponent($0, isDirectory: true) }.first(where: PathProbe.isDirectory)
                roots.append((account, root, myDrive))
            }
            discovery = roots.isEmpty ? .none : .found
        } catch {
            discovery = PathProbe.exists(cloudStorage) ? .notPermitted : .none
        }

        // Mirrored Google Drive keeps My Drive in the home folder.
        // Google Drive also places a "~/Google Drive" link to the streaming location; links that
        // lead to a root already found are the same drive, not another account.
        let known = Set(roots.compactMap { $0.myDrive?.resolvingSymlinksInPath().path })
        for mirrored in [home.appendingPathComponent("My Drive"), home.appendingPathComponent("Google Drive/My Drive")] where PathProbe.isDirectory(mirrored) {
            if known.contains(mirrored.resolvingSymlinksInPath().path) { continue }
            roots.append(("", mirrored.deletingLastPathComponent(), mirrored))
            if discovery != .found { discovery = .found }
        }

        func personal(_ account: String) -> Bool {
            let lower = account.lowercased()
            return lower.hasSuffix("@gmail.com") || lower.hasSuffix("@googlemail.com")
        }
        let ordered = roots.sorted { a, b in
            if (a.myDrive != nil) != (b.myDrive != nil) { return a.myDrive != nil }
            if personal(a.account) != personal(b.account) { return personal(a.account) }
            return a.account < b.account
        }

        if let best = ordered.first {
            let alternatives = ordered.dropFirst().compactMap { $0.myDrive ?? $0.root }
            if let myDrive = best.myDrive {
                return DestinationProposal(kind: .googleDrive, parent: myDrive, folder: myDrive.appendingPathComponent(destinationFolderName, isDirectory: true),
                                           status: .proposed, accountLabel: best.account.isEmpty ? nil : best.account, alternatives: alternatives, driveDiscovery: discovery)
            }
            return DestinationProposal(kind: .googleDrive, parent: best.root, folder: best.root.appendingPathComponent(destinationFolderName, isDirectory: true),
                                       status: .unresolved, accountLabel: best.account.isEmpty ? nil : best.account, alternatives: alternatives, driveDiscovery: discovery)
        }
        return DestinationProposal(kind: .documents, parent: documents, folder: documents.appendingPathComponent(destinationFolderName, isDirectory: true),
                                   status: .proposed, accountLabel: nil, alternatives: [], driveDiscovery: discovery)
    }
}
