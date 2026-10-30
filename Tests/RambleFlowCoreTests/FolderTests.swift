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

    @Test func unconfiguredFoldersAreNotUsed() {
        guard case .notGranted("not-configured") = ConfiguredFolders.source(AppConfig()) else { Issue.record("source"); return }
        guard case .notGranted("not-configured") = ConfiguredFolders.destination(AppConfig()) else { Issue.record("destination"); return }
    }

    @Test func sourceTellsDeniedFromMissing() throws {
        let temp = TempDir("folders")
        let source = temp.sub("Recordings")
        guard case .available = ConfiguredFolders.source(config(source: source)) else { Issue.record("available"); return }
        guard case .notGranted("missing") = ConfiguredFolders.source(config(source: temp.url.appendingPathComponent("Nope"))) else { Issue.record("missing"); return }
        guard getuid() != 0 else { return }
        chmod(source.path, 0o000)
        defer { chmod(source.path, 0o755) }
        guard case .notGranted("denied") = ConfiguredFolders.source(config(source: source)) else { Issue.record("denied"); return }
    }

    @Test func removedTranscriptsFolderIsRecreatedButAMissingDriveIsWaitedFor() throws {
        let temp = TempDir("dest")
        let parent = temp.sub("My Drive")
        let folder = parent.appendingPathComponent("Ramble Flow")
        guard case .available = ConfiguredFolders.destination(config(destination: folder)) else { Issue.record("recreate"); return }
        #expect(PathProbe.isDirectory(folder))
        // The whole drive is gone: wait, never write elsewhere and never recreate the drive.
        try FileManager.default.removeItem(at: parent)
        guard case .notGranted("missing") = ConfiguredFolders.destination(config(destination: folder)) else { Issue.record("missing"); return }
        #expect(!PathProbe.exists(parent))
    }

    @Test func readOnlyTranscriptsFolderIsReportedAsDenied() throws {
        guard getuid() != 0 else { return }
        let temp = TempDir("ro")
        let folder = temp.sub("Ramble Flow")
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }
        guard case .notGranted("denied") = ConfiguredFolders.destination(config(destination: folder)) else { Issue.record("denied"); return }
    }

    @Test func pathsAreExpandedLikeAShellWould() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(PathDisplay.expand("~/Documents/Ramble Flow", home: home).path == "/Users/example/Documents/Ramble Flow")
        #expect(PathDisplay.expand("  '/Volumes/Drive/My Folder'  ", home: home).path == "/Volumes/Drive/My Folder")
        #expect(PathDisplay.expand("/Volumes/Drive/My\\ Folder", home: home).path == "/Volumes/Drive/My Folder")
        #expect(PathDisplay.expand("notes", home: home, base: URL(fileURLWithPath: "/tmp/base")).path == "/tmp/base/notes")
        #expect(PathDisplay.tilde(URL(fileURLWithPath: "/Users/example/Library/Logs"), home: home) == "~/Library/Logs")
        #expect(PathDisplay.tilde(URL(fileURLWithPath: "/Users/example2/x"), home: home) == "/Users/example2/x")
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
