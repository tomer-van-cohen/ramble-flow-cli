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
            home: url, label: "io.example.ramble-flow-cli.test", binary: url.appendingPathComponent(".local/bin/ramble-flow"),
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

/// Answers the access check from a script; by default everything is fine and the probe really
/// runs in-process against the folders.
final class FakeVerifier: AccessVerifier {
    var sourceAnswers: [AccessReport.Source]
    private(set) var calls = 0
    init(_ answers: [AccessReport.Source] = []) { sourceAnswers = answers }
    func verify(source: URL, destination: URL) -> AccessReport? {
        calls += 1
        var report = AccessProbe.run(source: source, destination: destination)
        if !sourceAnswers.isEmpty { report.source = sourceAnswers.removeFirst() }
        return report
    }
}

final class Harness {
    let home: FakeHome
    let service = FakeService()
    var verifier = FakeVerifier()
    var opened: [[String]] = []
    var keyChecks: [String] = []
    var rejectKeysContaining = "rejected"
    var environment: [String: String] = [:]
    var lastOutput = ""

    init(drive: Bool = false) { home = FakeHome(drive: drive) }

    var layout: InstallLayout { home.layout }
    var config: AppConfig { ConfigStore(url: layout.paths.config).current }
    var keys: KeyFileStore { KeyFileStore(url: layout.paths.secrets, environment: [:]) }

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
            verifier: verifier, service: service,
            open: { [self] in opened.append($0) },
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
        // The transcripts folder was created by the access check, as the background process.
        #expect(PathProbe.isDirectory(URL(fileURLWithPath: config.destinationPath!)))
        // LaunchAgent written and started.
        #expect(h.service.bootstraps == [h.layout.label])
        let plist = try #require(NSDictionary(contentsOf: h.layout.plist) as? [String: Any])
        #expect(plist["Label"] as? String == h.layout.label)
        #expect((plist["ProgramArguments"] as? [String])?.prefix(2) == [h.layout.binary.path, "run"])
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

    @Test func fullDiskAccessIsGuidedAndVerifiedBeforeStarting() async throws {
        let h = Harness()
        h.verifier = FakeVerifier([.denied, .denied])
        let result = await h.run(["", groqKey, "", "", "", "", "", "", "x", ""], options: SetupOptions(binaryChanged: true))
        #expect(result.code == 0, "\(result.output)")
        #expect(h.verifier.calls == 3)
        #expect(h.opened.first == [SetupFlow.fullDiskAccessURL])
        #expect(h.opened.dropFirst().first == ["-R", h.layout.binary.path])
        #expect(result.output.contains("not permitted (macOS privacy protection)"))
        #expect(result.output.contains("remove it with the − button first"))
        #expect(result.output.contains("Still no access"))
        #expect(result.output.contains("Press Enter, s or o."))
        #expect(result.output.contains("Recordings folder    ok"))
        #expect(h.service.bootstraps == [h.layout.label])
    }

    @Test func permissionStepCanBeSkipped() async throws {
        let h = Harness()
        h.verifier = FakeVerifier([.denied])
        let result = await h.run(["", groqKey, "", "", "", "", "", "s"])
        #expect(result.code == 0)
        #expect(result.output.contains("Skipped."))
        #expect(h.config.setupCompleted, "it starts and waits for access; nothing is uploaded meanwhile")
        #expect(result.output.contains("starts watching once it can read the recordings folder"))
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

    @Test func probeReportsCountsWithoutNamesAndCreatesTheFolder() throws {
        let home = FakeHome()
        try Data().write(to: home.recordings.appendingPathComponent("20261030 101010-AAAA0001.m4a"))
        try Data().write(to: home.recordings.appendingPathComponent("20261030 101010-AAAA0001.waveform"))
        let destination = home.url.appendingPathComponent("Documents/Ramble Flow")
        let report = AccessProbe.run(source: home.recordings, destination: destination)
        #expect(report == AccessReport(source: .ok, recordings: 1, destination: .ok, destinationCreated: true))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "the write check leaves nothing behind")
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!json.contains("AAAA0001"))
    }

    @Test func probeTellsDeniedMissingAndUnwritableApart() throws {
        guard getuid() != 0 else { return }
        let home = FakeHome()
        chmod(home.recordings.path, 0o000)
        let missingDrive = home.url.appendingPathComponent("Library/CloudStorage/GoogleDrive-x/My Drive/Ramble Flow")
        var report = AccessProbe.run(source: home.recordings, destination: missingDrive)
        #expect(report.source == .denied)
        #expect(report.destination == .missing)
        chmod(home.recordings.path, 0o755)
        let readOnly = home.url.appendingPathComponent("Documents")
        chmod(readOnly.path, 0o555)
        report = AccessProbe.run(source: home.url.appendingPathComponent("nope"), destination: readOnly.appendingPathComponent("Ramble Flow"))
        #expect(report.source == .missing)
        #expect(report.destination == .denied || report.destination == .notWritable)
    }

    @Test func probeJobRunsTheInstalledBinaryWithoutOutputNoise() throws {
        let home = FakeHome()
        let plist = LaunchAgentPlist.probe(layout: home.layout, source: "/a", destination: "/b", output: URL(fileURLWithPath: "/tmp/out.json"))
        #expect(plist["Label"] as? String == home.layout.label + ".access-probe")
        #expect((plist["ProgramArguments"] as? [String]) == [home.layout.binary.path, "probe-access", "--source", "/a", "--destination", "/b", "--output", "/tmp/out.json"])
        #expect(plist["KeepAlive"] as? Bool == false)
    }

    @Test func layoutDerivesEverythingFromHomeAndLabel() throws {
        let layout = try InstallLayout.standard(environment: ["RAMBLE_FLOW_LABEL": "io.example.ramble.test-1", "RAMBLE_FLOW_BIN_DIR": "/tmp/rf-bin"])
        #expect(layout.label == "io.example.ramble.test-1")
        #expect(layout.binary.path == "/tmp/rf-bin/ramble-flow")
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
