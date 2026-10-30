import Darwin
import Foundation
import Testing
@testable import RambleFlowCLI
@testable import RambleFlowCore

/// A temporary home folder with the Voice Memos layout (synthetic, empty files only).
final class FakeHome {
    let url: URL
    let layout: InstallLayout

    init(drive: Bool = false) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ramble-flow-cli-tests/home-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try! fm.createDirectory(at: url.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: url.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"), withIntermediateDirectories: true)
        if drive {
            try! fm.createDirectory(at: url.appendingPathComponent("Library/CloudStorage/GoogleDrive-someone@example.com/My Drive"), withIntermediateDirectories: true)
        }
        let library = url.appendingPathComponent("Library")
        layout = InstallLayout(
            home: url, label: "io.example.ramble-flow-cli.test", app: url.appendingPathComponent("Applications/Ramble Flow.app"),
            paths: AppPaths(root: library.appendingPathComponent("Application Support/Ramble Flow CLI"), logs: library.appendingPathComponent("Logs/Ramble Flow CLI")),
            launchAgents: library.appendingPathComponent("LaunchAgents"))
    }

    var recordings: URL { url.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings") }

    deinit {
        if let e = FileManager.default.enumerator(atPath: url.path) {
            for case let p as String in e { chmod(url.appendingPathComponent(p).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

final class FakeService: ServiceManager {
    var loaded: Set<String> = []
    var bootstraps: [String] = []
    var bootouts: [String] = []
    func state(label: String) -> AgentState {
        loaded.contains(label) ? AgentState(loaded: true, running: true, pid: 4242, lastExitStatus: nil) : .notLoaded
    }
    func bootstrap(plist: URL, label: String) throws {
        bootstraps.append(label)
        loaded.insert(label)
    }
    func bootout(label: String) {
        bootouts.append(label)
        loaded.remove(label)
    }
}

/// Simulates the sandboxed app: a folder is accessible to it only once granted. The access check
/// reads the same grants.json the real app writes (paths only; bookmarks are not used here).
final class FakeVerifier: AccessVerifier {
    let layout: InstallLayout
    /// Grants that "stop working" (e.g. an upgrade that invalidated them).
    var invalidate: Set<String> = []
    private(set) var calls = 0
    init(layout: InstallLayout) { self.layout = layout }
    func verify() -> AccessReport? {
        calls += 1
        let config = ConfigStore(url: layout.paths.config).current
        let grants = GrantStore(url: layout.paths.grants).current
        var report = AccessReport(source: .notGranted, destination: .notGranted, sandboxed: true)
        if let path = config.sourcePath {
            if !PathProbe.isDirectory(URL(fileURLWithPath: path)) { report.source = .missing }
            else if let g = grants.source, GrantedFolders.samePath(g.path, path) {
                report.source = invalidate.contains("source") ? .denied : .ok
                if report.source == .ok { report.recordings = (try? VoiceMemosSource.listRecordings(in: URL(fileURLWithPath: path)))?.count ?? 0 }
            }
        }
        if let path = config.destinationPath, let g = grants.destination, GrantedFolders.samePath(g.path, path) {
            report.destination = invalidate.contains("destination") ? .denied : (PathProbe.isDirectory(URL(fileURLWithPath: path)) ? .ok : .missing)
        }
        return report
    }
}

/// Plays the folder dialog: grants exactly what was proposed, or what the script says.
final class FakeGranter: FolderGranter {
    enum Answer { case accept, cancel, choose(URL) }
    let layout: InstallLayout
    var answers: [Answer] = []
    private(set) var requests: [(source: URL?, destination: URL?)] = []
    init(layout: InstallLayout) { self.layout = layout }

    func requestGrants(source: URL?, destination: URL?) -> GrantOutcome? {
        requests.append((source, destination))
        let store = GrantStore(url: layout.paths.grants)
        var outcome = GrantOutcome()
        func next() -> Answer { answers.isEmpty ? .accept : answers.removeFirst() }
        if let source {
            switch next() {
            case .cancel: outcome.source = .init(status: .canceled); return outcome
            case .accept, .choose:
                try? store.update { $0.source = FolderGrants.Grant(path: source.path, bookmark: Data([1])) }
                outcome.source = .init(status: .granted, path: source.path)
            }
        }
        if let destination {
            var picked = PathProbe.isDirectory(destination) ? destination : destination.deletingLastPathComponent()
            switch next() {
            case .cancel: outcome.destination = .init(status: .canceled); return outcome
            case .choose(let url): picked = url
            case .accept: break
            }
            var target = picked
            if GrantedFolders.samePath(picked.path, destination.deletingLastPathComponent().path) { target = destination }
            let created = !PathProbe.isDirectory(target)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try? store.update { $0.destination = FolderGrants.Grant(path: target.path, bookmark: Data([2])) }
            outcome.destination = .init(status: .granted, path: target.path, created: created)
        }
        return outcome
    }
}

final class Harness {
    let home: FakeHome
    let service = FakeService()
    let verifier: FakeVerifier
    let granter: FakeGranter
    var keyChecks: [String] = []
    var rejectKeysContaining = "rejected"
    var environment: [String: String] = [:]
    var lastOutput = ""

    init(drive: Bool = false) {
        home = FakeHome(drive: drive)
        verifier = FakeVerifier(layout: home.layout)
        granter = FakeGranter(layout: home.layout)
    }

    var layout: InstallLayout { home.layout }
    var config: AppConfig { ConfigStore(url: layout.paths.config).current }
    var keys: KeyFileStore { KeyFileStore(url: layout.paths.secrets, environment: [:]) }
    var grants: FolderGrants { GrantStore(url: layout.paths.grants).current }

    @discardableResult
    func run(_ inputs: [String], options: SetupOptions = SetupOptions()) async -> (code: Int32, output: String, console: ScriptedConsole) {
        let console = ScriptedConsole(inputs)
        let home = self.home
        let context = SetupContext(
            layout: layout, console: console,
            credentials: KeyFileStore(url: layout.paths.secrets, environment: environment),
            keyCheck: { [self] _, key in
                keyChecks.append(key)
                return key.contains(rejectKeysContaining) ? .rejected("invalid_api_key") : .accepted
            },
            verifier: verifier, granter: granter, service: service,
            detectSource: { FolderLocator.detectSource(home: home.url) },
            proposeDestination: { FolderLocator.proposeDestination(home: home.url) },
            activationTimeout: 0.2)
        let code = await SetupFlow(context: context, options: options).run()
        lastOutput = console.output
        return (code, console.output, console)
    }
}

let groqKey = "gsk_synthetic_test_key_000000000000abcd"
let openAIKey = "sk-synthetic-test-key-0000000000000wxyz"

@Suite("Installer dialog", .serialized)
struct SetupTests {
    @Test func enterEnterEnterOnAFirstInstallUsesEveryDefault() async throws {
        let h = Harness()
        // Provider, key (no default the first time), recordings, transcripts, language, model, apply.
        let result = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(result.code == 0, "\(result.output)")
        let config = h.config
        #expect(config.provider == .groq)
        #expect(config.effectiveModel == "whisper-large-v3")
        #expect(config.model == nil)
        #expect(config.languageHint == nil)
        #expect(config.sourcePath == h.home.recordings.path)
        #expect(config.destinationPath == h.home.url.appendingPathComponent("Documents/Ramble Flow").path)
        #expect(config.setupCompleted)
        #expect(try h.keys.fileKey(for: .groq) == groqKey)
        #expect(h.keys.permissions() == 0o600)
        #expect(h.keyChecks == [groqKey])
        // Both folders were granted in one round of dialogs, then verified as the background app.
        #expect(h.granter.requests.count == 1)
        #expect(h.granter.requests.first?.source?.path == h.home.recordings.path)
        #expect(h.granter.requests.first?.destination?.path == config.destinationPath)
        #expect(h.grants.source?.path == h.home.recordings.path)
        #expect(h.grants.destination?.path == config.destinationPath)
        #expect(h.verifier.calls == 2)
        #expect(PathProbe.isDirectory(URL(fileURLWithPath: config.destinationPath!)), "created inside the chosen parent")
        #expect(result.output.contains("two standard macOS folder dialogs"))
        #expect(result.output.contains("(a \"Ramble Flow\" folder is created inside)"))
        #expect(!result.output.contains("Full Disk Access"))
        // LaunchAgent written and started.
        #expect(h.service.bootstraps == [h.layout.label])
        let plist = try #require(NSDictionary(contentsOf: h.layout.plist) as? [String: Any])
        #expect(plist["Label"] as? String == h.layout.label)
        #expect((plist["ProgramArguments"] as? [String])?.prefix(2) == [h.layout.agent.path, "run"])
        #expect((plist["AssociatedBundleIdentifiers"] as? [String]) == [Product.bundleIdentifier])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
        #expect(plist["EnvironmentVariables"] == nil, "a regular build passes no test settings to launchd")
        // The key never appears in output, settings or the plist.
        #expect(!result.output.contains(groqKey))
        #expect(result.output.contains("gsk_…abcd"))
        #expect(!(try String(contentsOf: h.layout.paths.config, encoding: .utf8)).contains("gsk_"))
        #expect(!(try String(contentsOf: h.layout.plist, encoding: .utf8)).contains("gsk_"))
        // Every question is numbered and shows its default.
        for marker in ["1/6", "2/6", "3/6", "4/6", "5/6", "6/6", "Provider [1]", "Language [auto]", "Model [whisper-large-v3]",
                       "Folder [~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings]", "Folder [~/Documents/Ramble Flow]",
                       "Apply these settings? [Y/n]"] {
            #expect(result.output.contains(marker), "missing: \(marker)")
        }
    }

    @Test func googleDriveIsTheDefaultDestinationWhenPresent() async throws {
        let h = Harness(drive: true)
        let result = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(result.code == 0)
        #expect(h.config.destinationPath == h.home.url.appendingPathComponent("Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/Ramble Flow").path)
        #expect(result.output.contains("Google Drive for desktop found"))
    }

    @Test func rerunShowsCurrentValuesAndKeepsKeyCutoffAndJobs() async throws {
        let h = Harness()
        _ = await h.run(["", groqKey, "", "", "", "", ""])
        // The background process established a cutoff and handled a recording meanwhile.
        let store = try JobStore(url: h.layout.paths.database)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        try store.activate(cutoff: cutoff, baselineStems: ["old"], now: cutoff)
        var record = RecordingRecord(stem: "20270115 101010-AAAA0001", fileName: "x.m4a", now: cutoff)
        record.state = .exported
        try store.save(record)

        let bootstrapsBefore = h.service.bootstraps.count
        // Change the language only: Enter everywhere else (the key prompt included).
        let result = await h.run(["", "", "", "", "he", "", ""])
        #expect(result.code == 0, "\(result.output)")
        #expect(result.output.contains("[keep gsk_…abcd]"))
        #expect(result.output.contains("Current settings are the defaults"))
        #expect(h.config.languageHint == "he")
        #expect(try h.keys.fileKey(for: .groq) == groqKey)
        #expect(h.keyChecks.count == 1, "a kept key is not checked again")
        #expect(try store.activation()?.cutoff == cutoff, "the cutoff is never moved by a rerun")
        #expect(try store.recordings().count == 1)
        #expect(h.service.bootstraps.count == bootstrapsBefore, "settings are picked up live; no restart needed")
        #expect(result.output.contains("picked up the new settings without a restart"))
        #expect(result.output.contains("kept from the first setup"))
        #expect(h.granter.requests.count == 1, "grants still valid: no dialog on a rerun")

        // The next rerun shows "he" as the default.
        let again = await h.run(["", "", "", "", "", "", ""])
        #expect(again.output.contains("Language [he]"))
        #expect(h.config.languageHint == "he")
    }

    @Test func switchingProviderAsksForThatProvidersKeyAndModel() async throws {
        let h = Harness()
        _ = await h.run(["", groqKey, "", "", "", "whisper-large-v3-turbo", ""])
        #expect(h.config.model == "whisper-large-v3-turbo")
        let result = await h.run(["2", "", openAIKey, "", "", "", "", ""])
        #expect(result.code == 0, "\(result.output)")
        #expect(result.output.contains("A key is needed"), "no OpenAI key was saved, so Enter alone is not accepted")
        #expect(result.output.contains("Model [gpt-transcribe]"), "the Groq model does not carry over")
        #expect(h.config.provider == .openai)
        #expect(h.config.model == nil)
        #expect(try h.keys.fileKey(for: .openai) == openAIKey)
        #expect(try h.keys.fileKey(for: .groq) == groqKey, "the other provider's key is kept")
    }

    @Test func rejectedKeyIsAskedAgain() async throws {
        let h = Harness()
        let result = await h.run(["", "gsk_this_key_is_rejected_0000000000", groqKey, "", "", "", "", ""])
        #expect(result.code == 0)
        #expect(result.output.contains("rejected (invalid_api_key)"))
        #expect(try h.keys.fileKey(for: .groq) == groqKey)
    }

    @Test func keyFromTheEnvironmentIsOfferedAsDefault() async throws {
        let h = Harness()
        h.environment = ["GROQ_API_KEY": groqKey]
        let result = await h.run(["", "", "", "", "", "", ""])
        #expect(result.code == 0, "\(result.output)")
        #expect(result.output.contains("[use $GROQ_API_KEY gsk_…abcd]"))
        #expect(try h.keys.fileKey(for: .groq) == groqKey, "saved, because launchd does not see the shell's environment")
    }

    @Test func invalidAnswersAreAskedAgain() async throws {
        let h = Harness()
        let result = await h.run(["3", "groq", "short", groqKey, "/does/not/exist", "", "", "english", "", "", "maybe", "y"])
        #expect(result.code == 0, "\(result.output)")
        #expect(result.output.contains("Please type 1 or 2."))
        #expect(result.output.contains("does not look like an API key"))
        #expect(result.output.contains("That folder does not exist."))
        #expect(result.output.contains("Type auto or a two-letter language code."))
        #expect(result.output.contains("Please answer y or n."))
    }

    @Test func customFoldersAndLanguageAreAccepted() async throws {
        let h = Harness()
        let custom = h.home.url.appendingPathComponent("Notes/Transcripts")
        try FileManager.default.createDirectory(at: custom.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = await h.run(["", groqKey, "", "~/Notes/Transcripts", "HE", "", ""])
        #expect(result.code == 0, "\(result.output)")
        #expect(h.config.destinationPath == custom.path)
        #expect(h.config.languageHint == "he")
        #expect(PathProbe.isDirectory(custom))
    }

    @Test func unrelatedFolderNeedsExplicitConfirmation() async throws {
        let h = Harness()
        let unrelated = h.home.url.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: unrelated.appendingPathComponent("song.m4a"))
        let result = await h.run(["", groqKey, "~/Downloads", "", "", "", "", "", ""])
        #expect(result.output.contains("does not look like a Voice Memos folder"))
        #expect(h.config.sourcePath == h.home.recordings.path, "declining keeps asking; Enter takes the detected folder")
    }

    @Test func cancelingTheDialogStartsNothingAndSaysHowToRetry() async throws {
        let h = Harness()
        h.granter.answers = [.cancel]
        let result = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(result.code == 1)
        #expect(result.output.contains("You canceled the folder dialog"))
        #expect(result.output.contains("Run ./install.sh again"))
        #expect(h.service.bootstraps.isEmpty, "nothing is started without both grants")
        #expect(!h.config.setupCompleted)
        #expect(try h.keys.fileKey(for: .groq) == groqKey, "answers are kept for the next run")
        // Next run: Enter everywhere, the dialog appears again, then everything starts.
        let again = await h.run(["", "", "", "", "", "", ""])
        #expect(again.code == 0, "\(again.output)")
        #expect(h.granter.requests.count == 2)
        #expect(h.service.bootstraps == [h.layout.label])
    }

    @Test func invalidatedGrantAfterAnUpgradeShowsTheDialogAgain() async throws {
        let h = Harness()
        _ = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(h.granter.requests.count == 1)
        // A rebuild made the recordings grant unusable: only that folder is asked for again.
        h.verifier.invalidate = ["source"]
        h.granter.answers = [.accept]
        let result = await h.run(["", "", "", "", "", "", "", "q"], options: SetupOptions(binaryChanged: true))
        #expect(result.output.contains("no longer granted"))
        #expect(h.granter.requests.count == 2)
        #expect(h.granter.requests.last?.source != nil)
        #expect(h.granter.requests.last?.destination == nil)
        // Still invalid in this fake, so the user is offered another try; "q" stops cleanly.
        #expect(result.output.contains("Access still does not work"))
        #expect(result.code == 1)
    }

    @Test func choosingAnotherTranscriptsFolderInTheDialogIsFollowed() async throws {
        let h = Harness()
        let other = h.home.url.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        h.granter.answers = [.accept, .choose(other)]
        let result = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(result.code == 0, "\(result.output)")
        #expect(h.config.destinationPath == other.path)
        #expect(result.output.contains("Transcripts folder is now ~/Notes"))
        #expect(result.output.contains("appear in ~/Notes"))
    }

    @Test func missingVoiceMemosFolderStopsWithAdvice() async throws {
        let h = Harness()
        try FileManager.default.removeItem(at: h.home.recordings)
        let result = await h.run(["", groqKey, "", "", "", "", ""])
        #expect(result.code == 1)
        #expect(result.output.contains("Turn on iCloud for Voice Memos"))
        #expect(h.granter.requests.isEmpty)
        #expect(h.service.bootstraps.isEmpty)
    }

    @Test func endOfInputStopsWithoutChangingAnything() async throws {
        let h = Harness()
        let result = await h.run(["", groqKey, ""])
        #expect(result.code == 2)
        #expect(result.output.contains("Setup stopped"))
        #expect(!PathProbe.exists(h.layout.paths.config))
        #expect(!PathProbe.exists(h.layout.paths.secrets))
        #expect(h.service.bootstraps.isEmpty)
    }

    @Test func answeringNoAtTheSummaryChangesNothing() async throws {
        let h = Harness()
        let result = await h.run(["", groqKey, "", "", "", "", "n"])
        #expect(result.code == 1)
        #expect(result.output.contains("Nothing was changed."))
        #expect(!PathProbe.exists(h.layout.paths.secrets))
        #expect(h.service.bootstraps.isEmpty)
    }
}

@Suite("LaunchAgent, access probe and helpers")
struct AgentTests {
    @Test func launchctlOutputIsParsed() {
        let running = Launchctl.parse("gui/501/io.example = {\n\tactive count = 1\n\tstate = running\n\tpid = 1234\n\tlast exit code = (never exited)\n\tendpoints = {\n\t\tstate = active\n\t\tpid = 99\n\t}\n}\n")
        #expect(running == AgentState(loaded: true, running: true, pid: 1234, lastExitStatus: "(never exited)"))
        let stopped = Launchctl.parse("x = {\n\tstate = not running\n\tlast exit code = 1\n\tsockets = {\n\t\tstate = running\n\t}\n}\n")
        #expect(!stopped.running)
        #expect(stopped.lastExitStatus == "1")
    }

    @Test func probeWithoutGrantsReportsNotGranted() throws {
        let home = FakeHome()
        try home.layout.paths.createDirectories()
        try ConfigStore(url: home.layout.paths.config).update {
            $0.sourcePath = home.recordings.path
            $0.destinationPath = home.url.appendingPathComponent("Documents/Ramble Flow").path
        }
        let report = AccessProbe.run(paths: home.layout.paths)
        #expect(report.source == .notGranted)
        #expect(report.destination == .notGranted)
        #expect(!report.allOK)
    }

    @Test func probeJobRunsTheAppInsideItsSandbox() throws {
        let home = FakeHome()
        let plist = LaunchAgentPlist.probe(layout: home.layout, output: URL(fileURLWithPath: "/tmp/out.json"))
        #expect(plist["Label"] as? String == home.layout.label + ".access-probe")
        #expect((plist["ProgramArguments"] as? [String]) == [home.layout.agent.path, "probe-access", "--support-dir", home.layout.paths.root.path, "--output", "/tmp/out.json"])
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(home.layout.agent.path.hasSuffix("Ramble Flow.app/Contents/MacOS/RambleFlow"))
        #expect(home.layout.cli.path.hasSuffix("Ramble Flow.app/Contents/MacOS/ramble-flow"))
    }

    @Test func grantRecorderCreatesTheFolderInsideTheChosenParent() throws {
        let home = FakeHome()
        try home.layout.paths.createDirectories()
        let store = GrantStore(url: home.layout.paths.grants)
        let intended = home.url.appendingPathComponent("Documents/Ramble Flow")
        let answer = GrantRecorder.recordDestination(picked: home.url.appendingPathComponent("Documents"), intended: intended, grants: store)
        #expect(answer.status == .granted)
        #expect(answer.created)
        #expect(answer.path == intended.standardizedFileURL.path)
        #expect(PathProbe.isDirectory(intended))
        #expect(store.current.destination?.path == intended.standardizedFileURL.path)
        #expect(!(store.current.destination?.bookmark.isEmpty ?? true))
        // Choosing an unrelated folder makes it the transcripts folder as is.
        let other = home.url.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = GrantRecorder.recordDestination(picked: other, intended: intended, grants: store)
        #expect(second.path == other.standardizedFileURL.path)
        #expect(!second.created)
        let source = GrantRecorder.recordSource(picked: home.recordings, grants: store)
        #expect(source.status == .granted)
        #expect(store.current.source?.path == home.recordings.standardizedFileURL.path)
        let mode = (try FileManager.default.attributesOfItem(atPath: home.layout.paths.grants.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func grantsResolveToTheGrantedFoldersOnly() throws {
        let home = FakeHome()
        try home.layout.paths.createDirectories()
        let store = GrantStore(url: home.layout.paths.grants)
        _ = GrantRecorder.recordSource(picked: home.recordings, grants: store)
        let folders = GrantedFolders(grants: store)
        var config = AppConfig()
        config.sourcePath = home.recordings.path
        guard case .available = folders.source(config) else { Issue.record("granted folder should resolve"); return }
        config.sourcePath = home.url.appendingPathComponent("Documents").path
        guard case .notGranted("grant-for-another-folder") = folders.source(config) else { Issue.record("other folder"); return }
        config.sourcePath = nil
        guard case .notGranted("not-configured") = folders.source(config) else { Issue.record("unconfigured"); return }
        guard case .notGranted("no-grant") = folders.destination({ var c = AppConfig(); c.destinationPath = "/x"; return c }()) else { Issue.record("no grant"); return }
    }

    @Test func layoutDerivesEverythingFromHomeAndLabel() throws {
        let layout = try InstallLayout.standard(environment: ["RAMBLE_FLOW_LABEL": "io.example.ramble.test-1", "RAMBLE_FLOW_APP_DIR": "/tmp/rf-apps"])
        #expect(layout.label == "io.example.ramble.test-1")
        #expect(layout.app.path == "/tmp/rf-apps/Ramble Flow.app")
        #expect(layout.plist.lastPathComponent == "io.example.ramble.test-1.plist")
        #expect(layout.paths.root.path.hasSuffix("Library/Application Support/Ramble Flow CLI"))
        #expect(layout.paths.logs.path.hasSuffix("Library/Logs/Ramble Flow CLI"))
        #expect(layout.shellAssignments().contains("RF_SECRETS='"))
        #expect(throws: (any Error).self) { try InstallLayout.standard(environment: ["RAMBLE_FLOW_LABEL": "bad label; rm -rf"]) }
    }

    @Test func keysAreMaskedForDisplay() {
        #expect(SetupFlow.mask("gsk_abcdefghijklmnopqrstuvwxyz1234") == "gsk_…1234")
        #expect(SetupFlow.mask("sk-proj-abcdefghijklmnopqrstuvwxyz9876") == "sk-proj-…9876")
        #expect(SetupFlow.mask("short") == "••••")
        #expect(!SetupFlow.plausibleKey("has space in it 000000000000"))
        #expect(SetupFlow.plausibleKey(groqKey))
    }

    @Test func statusDescriptionsCoverEveryWorkerPhase() {
        let phases = ["notActivated", "paused", "needsKey", "credentialsUnreadable", "needsSourceAccess", "needsDestinationAccess",
                      "outputUnavailable", "transcribing", "waitingForInternet", "waitingForProviderLimit", "needsAttention", "watching"]
        for phase in phases {
            #expect(WorkerStatus.Phase(rawValue: phase) != nil, "\(phase)")
            #expect(Commands.describe(phase: phase, detail: nil) != phase || phase == "watching" || phase == "transcribing")
        }
    }
}
