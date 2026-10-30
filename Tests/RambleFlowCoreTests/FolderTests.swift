import Darwin
import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Configured folders and paths")
struct FolderTests {
    func config(source: URL? = nil, destination: URL? = nil) -> AppConfig {
        var c = AppConfig()
        c.sourcePath = source?.path
        c.destinationPath = destination?.path
        return c
    }

    func granted(_ temp: TempDir, source: URL? = nil, destination: URL? = nil) throws -> GrantedFolders {
        let store = GrantStore(url: temp.url.appendingPathComponent("grants.json"))
        try store.update {
            if let source { $0.source = FolderGrants.Grant(path: source.path, bookmark: try! Bookmarks.create(for: source, readOnly: true)) }
            if let destination { $0.destination = FolderGrants.Grant(path: destination.path, bookmark: try! Bookmarks.create(for: destination, readOnly: false)) }
        }
        return GrantedFolders(grants: store)
    }

    @Test func unconfiguredOrUngrantedFoldersAreNotUsed() throws {
        let temp = TempDir("folders")
        let folders = try granted(temp)
        guard case .notGranted("not-configured") = folders.source(AppConfig()) else { Issue.record("source"); return }
        guard case .notGranted("not-configured") = folders.destination(AppConfig()) else { Issue.record("destination"); return }
        guard case .notGranted("no-grant") = folders.source(config(source: temp.sub("R"))) else { Issue.record("no grant"); return }
    }

    @Test func grantedSourceTellsDeniedFromMissing() throws {
        let temp = TempDir("folders")
        let source = temp.sub("Recordings")
        let folders = try granted(temp, source: source)
        guard case .available(let folder) = folders.source(config(source: source)) else { Issue.record("available"); return }
        #expect(folder.url.standardizedFileURL.resolvingSymlinksInPath().path == source.standardizedFileURL.resolvingSymlinksInPath().path)
        guard getuid() != 0 else { return }
        chmod(source.path, 0o000)
        guard case .notGranted("denied") = GrantedFolders(grants: GrantStore(url: temp.url.appendingPathComponent("grants.json"))).source(config(source: source)) else {
            chmod(source.path, 0o755); Issue.record("denied"); return
        }
        chmod(source.path, 0o755)
        try FileManager.default.removeItem(at: source)
        guard case .notGranted("missing") = GrantedFolders(grants: GrantStore(url: temp.url.appendingPathComponent("grants.json"))).source(config(source: source)) else { Issue.record("missing"); return }
    }

    @Test func aGrantForAnotherFolderIsNotUsed() throws {
        let temp = TempDir("folders")
        let a = temp.sub("A"), b = temp.sub("B")
        let folders = try granted(temp, source: a, destination: a)
        guard case .notGranted("grant-for-another-folder") = folders.source(config(source: b)) else { Issue.record("source"); return }
        guard case .notGranted("grant-for-another-folder") = folders.destination(config(destination: b)) else { Issue.record("destination"); return }
    }

    @Test func goneTranscriptsFolderIsWaitedForNeverReplaced() throws {
        let temp = TempDir("dest")
        let parent = temp.sub("My Drive")
        let folder = parent.appendingPathComponent("Ramble Flow")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folders = try granted(temp, destination: folder)
        guard case .available = folders.destination(config(destination: folder)) else { Issue.record("available"); return }
        try FileManager.default.removeItem(at: parent)
        let fresh = GrantedFolders(grants: GrantStore(url: temp.url.appendingPathComponent("grants.json")))
        guard case .notGranted("missing") = fresh.destination(config(destination: folder)) else { Issue.record("missing"); return }
        #expect(!PathProbe.exists(parent), "nothing is recreated or written elsewhere")
    }

    @Test func readOnlyTranscriptsFolderIsReportedAsDenied() throws {
        guard getuid() != 0 else { return }
        let temp = TempDir("ro")
        let folder = temp.sub("Ramble Flow")
        let folders = try granted(temp, destination: folder)
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }
        guard case .notGranted("denied") = folders.destination(config(destination: folder)) else { Issue.record("denied"); return }
    }

    @Test func grantsWrittenByOneProcessAreSeenByAnother() throws {
        let temp = TempDir("grants")
        let url = temp.url.appendingPathComponent("grants.json")
        let reader = GrantStore(url: url)
        #expect(reader.current.source == nil)
        try GrantStore(url: url).update { $0.source = FolderGrants.Grant(path: "/x", bookmark: Data([1, 2])) }
        #expect(reader.current.source?.path == "/x")
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func pathsAreExpandedLikeAShellWould() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(PathDisplay.expand("~/Documents/Ramble Flow", home: home).path == "/Users/example/Documents/Ramble Flow")
        #expect(PathDisplay.expand("  '/Volumes/Drive/My Folder'  ", home: home).path == "/Volumes/Drive/My Folder")
        #expect(PathDisplay.expand("/Volumes/Drive/My\\ Folder", home: home).path == "/Volumes/Drive/My Folder")
        #expect(PathDisplay.expand("notes", home: home, base: URL(fileURLWithPath: "/tmp/base")).path == "/tmp/base/notes")
        #expect(PathDisplay.tilde(URL(fileURLWithPath: "/Users/example/Library/Logs"), home: home) == "~/Library/Logs")
        #expect(PathDisplay.tilde(URL(fileURLWithPath: "/Users/example2/x"), home: home) == "/Users/example2/x")
        #expect(PathDisplay.tilde(URL(fileURLWithPath: "/private/var/tmp-home/Docs"), home: URL(fileURLWithPath: "/var/tmp-home")) == "~/Docs")
    }

    @Test func privateFoldersAreOwnerOnly() throws {
        let temp = TempDir("paths")
        let paths = AppPaths(root: temp.url.appendingPathComponent("Support"), logs: temp.url.appendingPathComponent("Logs"))
        try paths.createDirectories()
        for dir in [paths.root, paths.work] {
            let mode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
            #expect(mode == 0o700)
        }
        #expect(paths.secrets.lastPathComponent == "secrets.env")
        #expect(paths.secrets.deletingLastPathComponent().path == paths.root.path)
    }
}
