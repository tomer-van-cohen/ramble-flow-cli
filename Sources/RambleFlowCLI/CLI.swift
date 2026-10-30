import Darwin
import Foundation
import RambleFlowCore

/// `ramble-flow <command>`.
public enum CLI {
    public static let usage = """
    Ramble Flow \(Product.version): new Voice Memos recordings → text files, in the background.

    Usage: ramble-flow <command>

      status [--json]        what the background process is doing
      list [--all]           recordings it knows about (newest first)
      retry <id>|--all       try again a recording that needs attention
      approve <id>           transcribe a recording whose age could not be established
      skip <id>              never transcribe that recording
      pause | resume         stop / restart uploading (the process keeps running)
      logs [-n LINES]        the end of the log
      version

    Used by ./install.sh:
      setup                  the interactive setup; run ./install.sh instead
      paths                  where everything is installed

    The background work itself runs in Ramble Flow.app (started at login by a LaunchAgent).

    Change settings: run ./install.sh again from your clone. Uninstall: ./install.sh --uninstall.
    """

    public static func main(_ arguments: [String]) async -> Int32 {
        var args = Array(arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            return 0
        }
        args.removeFirst()
        switch command {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "version", "--version":
            print("ramble-flow \(Product.version)")
            return 0
        default:
            break
        }
        let layout: InstallLayout
        do {
            layout = try InstallLayout.standard()
        } catch {
            fputs("ramble-flow: \(error)\n", stderr)
            return 2
        }
        switch command {
        case "paths":
            print(layout.shellAssignments())
            return 0
        case "setup":
            umask(0o077)
            let options = SetupOptions(binaryChanged: args.contains("--binary-changed"), skipKeyCheck: args.contains("--skip-key-check"))
            return await SetupFlow(context: .standard(layout: layout), options: options).run()
        case "status":
            return Commands(layout: layout).status(json: args.contains("--json"))
        case "list":
            return Commands(layout: layout).list(all: args.contains("--all"))
        case "retry", "approve", "skip":
            return await Commands(layout: layout).act(command, target: args.first)
        case "pause", "resume":
            return Commands(layout: layout).setPaused(command == "pause")
        case "logs":
            let lines = value(of: "-n", in: args).flatMap(Int.init) ?? 40
            return Commands(layout: layout).logs(lines: lines)
        default:
            fputs("ramble-flow: unknown command \(command). See: ramble-flow help\n", stderr)
            return 2
        }
    }

    static func value(of flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// The small management commands. They read the same files as the background process and change
/// job rows directly; the running process picks the change up on its next pass (about 10 s).
struct Commands {
    let layout: InstallLayout
    var paths: AppPaths { layout.paths }

    private func openStore() -> JobStore? {
        guard PathProbe.exists(paths.database) else { return nil }
        return try? JobStore(url: paths.database)
    }

    func status(json: Bool) -> Int32 {
        let configStore = ConfigStore(url: paths.config)
        let config = configStore.current
        let agent = Launchctl().state(label: layout.label)
        let file = StatusFile.read(paths.status)
        let store = openStore()
        let activation = (try? store?.activation()) ?? nil
        let credentials = KeyFileStore(url: paths.secrets, environment: [:])
        let savedKey = (try? credentials.fileKey(for: config.provider)) ?? nil
        let permissions = credentials.permissions()
        let installed = PathProbe.exists(layout.plist)

        if json {
            var object: [String: Any] = [
                "installed": installed,
                "setupCompleted": config.setupCompleted,
                "agentLoaded": agent.loaded,
                "agentRunning": agent.running,
                "provider": config.provider.rawValue,
                "model": config.effectiveModel,
                "language": config.languageHint ?? "auto",
                "paused": config.paused,
                "keySaved": savedKey != nil,
                "sourceGranted": GrantStore(url: paths.grants).current.source != nil,
                "destinationGranted": GrantStore(url: paths.grants).current.destination != nil,
                "sourcePath": config.sourcePath ?? NSNull(),
                "destinationPath": config.destinationPath ?? NSNull(),
            ]
            if let pid = agent.pid { object["pid"] = pid }
            if let permissions { object["secretsMode"] = String(permissions, radix: 8) }
            if let activation { object["cutoff"] = ISO8601DateFormatter().string(from: activation.cutoff) }
            if let file {
                object["phase"] = file.phase
                object["detail"] = file.detail ?? NSNull()
                object["pending"] = file.pending
                object["attention"] = file.attention
                object["undecided"] = file.undecided
                object["updatedAt"] = ISO8601DateFormatter().string(from: file.updatedAt)
            }
            if let counts = try? store?.stateCounts() {
                object["states"] = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
            }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return 0
        }

        let home = layout.home
        print("Ramble Flow \(Product.version)")
        guard config.setupCompleted || installed else {
            print("  Not set up. Run ./install.sh from your clone.")
            return 1
        }
        row("App", PathDisplay.tilde(layout.app, home: home))
        var processLine = agent.running ? "running\(agent.pid.map { " (pid \($0))" } ?? "")" : (agent.loaded ? "loaded, not running (last exit \(agent.lastExitStatus ?? "?"))" : "not loaded")
        if installed { processLine += ", starts at login" }
        row("Background process", processLine)
        if let file, agent.running {
            let age = Int(Date().timeIntervalSince(file.updatedAt))
            row("State", "\(Self.describe(phase: file.phase, detail: file.detail)) (checked \(age) s ago)")
        } else if config.paused {
            row("State", "paused")
        }
        var keyLine = savedKey.map { SetupFlow.mask($0) } ?? "missing"
        if let permissions, permissions & 0o077 != 0 { keyLine += " — WARNING: secrets.env is readable by others (mode \(String(permissions, radix: 8))); run chmod 600 on it" }
        row("Provider", "\(config.provider.displayName) / \(config.effectiveModel), key \(keyLine)")
        row("Language", config.languageHint ?? "auto")
        let grants = GrantStore(url: paths.grants).current
        func grantNote(_ grant: FolderGrants.Grant?, _ path: String) -> String {
            guard let grant else { return " (not granted)" }
            return GrantedFolders.samePath(grant.path, path) ? " (granted)" : " (granted for another folder)"
        }
        if let path = config.sourcePath { row("Recordings", PathDisplay.tilde(URL(fileURLWithPath: path), home: home) + grantNote(grants.source, path)) }
        if let path = config.destinationPath { row("Transcripts", PathDisplay.tilde(URL(fileURLWithPath: path), home: home) + grantNote(grants.destination, path)) }
        if let activation {
            row("New recordings since", SetupFlow.displayDate(activation.cutoff))
        } else {
            row("New recordings since", "not started yet (waiting to read the recordings folder)")
        }
        if let file {
            row("Queue", "\(file.pending) in progress, \(file.attention) need attention, \(file.undecided) undecided")
            if let name = file.lastExportedName, let at = file.lastExportedAt {
                row("Last transcript", "\(name) (\(SetupFlow.displayDate(at)))")
            }
            if file.attention + file.undecided > 0 { print("  See: ramble-flow list") }
        }
        row("Log", PathDisplay.tilde(layout.logFile, home: home))
        return 0
    }

    private func row(_ label: String, _ value: String) {
        print("  " + label.padding(toLength: 21, withPad: " ", startingAt: 0) + value)
    }

    static func describe(phase: String, detail: String?) -> String {
        switch phase {
        case "watching": return "watching"
        case "transcribing": return "transcribing"
        case "paused": return "paused (ramble-flow resume)"
        case "needsKey": return "needs a valid API key (run ./install.sh)"
        case "credentialsUnreadable": return "cannot read secrets.env"
        case "needsSourceAccess":
            return detail == "missing"
                ? "recordings folder not found"
                : "cannot read the recordings folder: run ./install.sh to grant it again"
        case "needsDestinationAccess": return "cannot write to the transcripts folder: run ./install.sh to grant it again"
        case "outputUnavailable": return "transcripts folder unavailable (Drive offline or folder gone); results wait"
        case "waitingForInternet": return "waiting for the internet"
        case "waitingForProviderLimit": return detail == "quota" ? "provider quota or billing limit reached" : "waiting for the provider's rate limit"
        case "needsAttention": return "a recording needs attention (ramble-flow list)"
        case "notActivated": return "starting (waiting to read the recordings folder)"
        case "notConfigured": return "not configured"
        default: return phase
        }
    }

    func list(all: Bool) -> Int32 {
        guard let store = openStore(), let records = try? store.recordings() else {
            print("No recordings yet.")
            return 0
        }
        let shown = records.filter { all || $0.state != .excluded }
            .sorted { ($0.recordedAt ?? $0.firstSeenAt) > ($1.recordedAt ?? $1.firstSeenAt) }
            .prefix(all ? Int.max : 30)
        if shown.isEmpty {
            print(all ? "No recordings yet." : "No new recordings yet. (Recordings from before setup are never uploaded; --all shows them.)")
            return 0
        }
        print("ID        STATE              RECORDED                    TITLE / NOTE")
        for r in shown {
            let recorded = r.recordedAt.map { SetupFlow.displayDate($0) } ?? "unknown"
            var note = TranscriptNaming.cleanTitle(r.title) ?? TranscriptDocument.genericTitle
            if let reason = r.reason, r.state != .exported { note += "  (\(reason))" }
            if r.state == .needsDecision { note += "  → ramble-flow approve|skip \(r.reference)" }
            if [.needsAttention, .providerOutcomeUnknown, .unsupportedAudio].contains(r.state) { note += "  → ramble-flow retry \(r.reference)" }
            print("\(r.reference)  \(r.state.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0))  \(recorded.padding(toLength: 26, withPad: " ", startingAt: 0))  \(note)")
        }
        return 0
    }

    func act(_ command: String, target: String?) async -> Int32 {
        guard let store = openStore() else {
            print("Nothing to \(command): no recordings yet.")
            return 1
        }
        let worker = TranscriptionWorker(dependencies: Daemon.dependencies(paths: paths, store: store, config: ConfigStore(url: paths.config)))
        do {
            if command == "retry", target == "--all" {
                try await worker.retryAll()
                print("Retrying every recording that needed attention.")
                return 0
            }
            guard let target, let record = try store.recordings().first(where: { $0.reference == target.lowercased() }) else {
                print("No recording with id \(target ?? "?"). See: ramble-flow list")
                return 1
            }
            switch command {
            case "approve":
                guard record.state == .needsDecision else { print("\(target) is not waiting for a decision."); return 1 }
                try await worker.approve(jobID: record.id)
                print("\(target) will be transcribed.")
            case "skip":
                guard record.state == .needsDecision else { print("\(target) is not waiting for a decision."); return 1 }
                try await worker.skip(jobID: record.id)
                print("\(target) will not be transcribed.")
            default:
                try await worker.retry(jobID: record.id)
                print("\(target) will be retried on the next pass.")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    func setPaused(_ paused: Bool) -> Int32 {
        guard PathProbe.exists(paths.config) else {
            print("Not set up. Run ./install.sh from your clone.")
            return 1
        }
        do {
            try ConfigStore(url: paths.config).update { $0.paused = paused }
            print(paused ? "Paused. Nothing is uploaded until: ramble-flow resume" : "Resumed.")
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }

    func logs(lines: Int) -> Int32 {
        guard let text = try? String(contentsOf: layout.logFile, encoding: .utf8) else {
            print("No log yet at \(layout.logFile.path)")
            return 1
        }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in all.suffix(lines + 1) where !line.isEmpty { print(line) }
        return 0
    }
}
