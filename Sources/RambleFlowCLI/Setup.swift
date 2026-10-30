import Foundation
import RambleFlowCore

/// Everything the setup dialog talks to, injectable for tests.
public struct SetupContext {
    public var layout: InstallLayout
    public var console: Console
    public var credentials: KeyFileStore
    public var keyCheck: (ProviderID, String) async -> KeyCheck
    /// Checks folder access as the background app (launchd one-shot job).
    public var verifier: AccessVerifier
    /// Shows the native folder dialog(s) through Ramble Flow.app.
    public var granter: FolderGranter
    public var service: ServiceManager
    public var detectSource: () -> SourceDetection
    public var proposeDestination: () -> DestinationProposal
    /// How long to wait for the background process to establish the cutoff.
    public var activationTimeout: TimeInterval

    public init(layout: InstallLayout, console: Console, credentials: KeyFileStore, keyCheck: @escaping (ProviderID, String) async -> KeyCheck,
                verifier: AccessVerifier, granter: FolderGranter, service: ServiceManager,
                detectSource: @escaping () -> SourceDetection, proposeDestination: @escaping () -> DestinationProposal,
                activationTimeout: TimeInterval = 30) {
        self.layout = layout
        self.console = console
        self.credentials = credentials
        self.keyCheck = keyCheck
        self.verifier = verifier
        self.granter = granter
        self.service = service
        self.detectSource = detectSource
        self.proposeDestination = proposeDestination
        self.activationTimeout = activationTimeout
    }

    /// The real thing: Terminal, launchd, Ramble Flow.app's folder dialog, the provider's key check.
    public static func standard(layout: InstallLayout, environment: [String: String] = ProcessInfo.processInfo.environment) -> SetupContext {
        let service = Launchctl()
        let transport = URLSessionTransport()
        let uploads = layout.paths.work.appendingPathComponent("uploads", isDirectory: true)
        return SetupContext(
            layout: layout, console: StandardConsole(),
            credentials: KeyFileStore(url: layout.paths.secrets, environment: environment),
            keyCheck: { id, key in await Providers.make(id, model: id.defaultModel, transport: transport, temporaryDirectory: uploads).checkKey(key) },
            verifier: LaunchdAccessVerifier(layout: layout, service: service),
            granter: AppFolderGranter(layout: layout, environment: environment),
            service: service,
            detectSource: { FolderLocator.detectSource(home: layout.home) },
            proposeDestination: { FolderLocator.proposeDestination(home: layout.home) })
    }
}

public struct SetupOptions: Equatable {
    /// The installer replaced the app with a different build: restart the background process.
    /// (Folder grants usually survive a rebuild; if not, the access check shows the dialog again.)
    public var binaryChanged = false
    public var skipKeyCheck = false
    public init(binaryChanged: Bool = false, skipKeyCheck: Bool = false) {
        self.binaryChanged = binaryChanged
        self.skipKeyCheck = skipKeyCheck
    }
}

/// The interactive installer dialog. Every question has a default, so pressing Enter accepts it;
/// on a rerun the current settings are the defaults and the API key, the cutoff and job state
/// are kept unless changed.
public final class SetupFlow {
    let ctx: SetupContext
    let options: SetupOptions
    var console: Console { ctx.console }
    var layout: InstallLayout { ctx.layout }

    static let questionCount = 6

    public init(context: SetupContext, options: SetupOptions = SetupOptions()) {
        ctx = context
        self.options = options
    }

    struct Stop: Error { var code: Int32 }

    public func run() async -> Int32 {
        do {
            return try await runSteps()
        } catch let stop as Stop {
            return stop.code
        } catch {
            console.line("error: \(error)")
            return 1
        }
    }

    // MARK: - Steps

    private func runSteps() async throws -> Int32 {
        try layout.paths.createDirectories()
        let configStore = ConfigStore(url: layout.paths.config)
        let existing = configStore.exists ? configStore.current : nil
        let activation = existingActivation()

        console.line("")
        console.line("\(Product.name) \(Product.version) — setup")
        console.line("Turns new Voice Memos recordings into text files, in the background.")
        console.line("Press Enter to accept the value in [brackets].")
        if existing?.setupCompleted == true {
            var kept = "Current settings are the defaults. Your API key and job history are kept"
            if let activation { kept += ", and so is the new-recordings cutoff (\(Self.displayDate(activation.cutoff)))" }
            console.line(kept + ".")
        }

        // 1. Provider
        let provider = try askProvider(current: existing?.provider ?? .groq)

        // 2. API key
        let key = try await askKey(provider: provider)

        // 3. Recordings folder
        let source = try askSource(current: existing?.sourcePath)

        // 4. Transcripts folder
        let destination = try askDestination(current: existing?.destinationPath)

        // 5. Language
        let language = try askLanguage(current: existing?.languageHint)

        // 6. Model
        let model = try askModel(provider: provider, current: existing?.provider == provider ? existing?.model : nil)

        // Summary
        console.line("")
        console.line("Summary")
        console.line("  Provider      \(provider.displayName) / \(model ?? provider.defaultModel)")
        console.line("  API key       \(Self.mask(key.value)) \(key.fromEnvironment ? "(from $\(provider.environmentVariable), saved to secrets.env)" : "(secrets.env, readable only by you)")")
        console.line("  Recordings    \(PathDisplay.tilde(source, home: layout.home))")
        console.line("  Transcripts   \(PathDisplay.tilde(destination, home: layout.home))")
        console.line("  Language      \(language ?? "auto")")
        guard try askYesNo("  Apply these settings?", default: true) else {
            console.line("Nothing was changed.")
            return 1
        }

        // Apply settings. The background process (if running) picks them up within a second.
        if key.changed {
            try ctx.credentials.setKey(key.value, for: provider)
        }
        let wasCompleted = existing?.setupCompleted ?? false
        try configStore.update { config in
            config.provider = provider
            config.model = model
            config.languageHint = language
            config.sourcePath = source.path
            config.destinationPath = destination.path
            config.setupCompleted = wasCompleted
        }
        console.line("  Saved \(PathDisplay.tilde(layout.paths.config, home: layout.home)).")

        // Folder access: native folder dialogs, then a check as the background app itself.
        guard let access = try grantAndVerify(source: source, destination: destination, configStore: configStore) else {
            console.line("")
            console.line("Your settings are saved, but Ramble Flow has not started: it needs both folders.")
            console.line("Run ./install.sh again (Enter keeps every answer) to show the folder dialog again.")
            return 1
        }
        let finalDestination = access.destination

        // Background process
        try configStore.update { $0.setupCompleted = true }
        try startAgent()
        await reportActivation(previous: activation)

        console.line("")
        console.line("Done. Transcripts of new recordings will appear in \(PathDisplay.tilde(finalDestination, home: layout.home)).")
        console.line("  Status            ./install.sh --status")
        console.line("  Log               \(PathDisplay.tilde(layout.logFile, home: layout.home))")
        console.line("  Change settings   ./install.sh")
        console.line("  Uninstall         ./install.sh --uninstall")
        return 0
    }

    // MARK: Questions

    private func ask(_ prompt: String, default value: String?) throws -> String {
        console.write(value.map { "\(prompt) [\($0)]: " } ?? "\(prompt): ")
        guard let answer = console.readLine() else { throw endOfInput() }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (value ?? "") : trimmed
    }

    private func endOfInput() -> Stop {
        console.line("")
        console.line("Setup stopped: no more input. Run ./install.sh again to finish.")
        return Stop(code: 2)
    }

    func askYesNo(_ prompt: String, default value: Bool) throws -> Bool {
        while true {
            console.write("\(prompt) [\(value ? "Y/n" : "y/N")]: ")
            guard let raw = console.readLine() else { throw endOfInput() }
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "": return value
            case "y", "yes": return true
            case "n", "no": return false
            default: console.line("     Please answer y or n.")
            }
        }
    }

    private func header(_ number: Int, _ title: String) {
        console.line("")
        console.line("\(number)/\(Self.questionCount)  \(title)")
    }

    private func askProvider(current: ProviderID) throws -> ProviderID {
        header(1, "Transcription provider")
        console.line("     1) Groq    whisper-large-v3; has a free tier with rate limits")
        console.line("     2) OpenAI  gpt-transcribe")
        console.line("     Audio of new recordings is sent only to the provider you choose.")
        let defaultIndex = current == .groq ? "1" : "2"
        while true {
            switch try ask("     Provider", default: defaultIndex).lowercased() {
            case "1", "groq": return .groq
            case "2", "openai": return .openai
            default: console.line("     Please type 1 or 2.")
            }
        }
    }

    struct KeyAnswer {
        var value: String
        var changed: Bool
        var fromEnvironment: Bool
    }

    private func askKey(provider: ProviderID) async throws -> KeyAnswer {
        header(2, "\(provider.displayName) API key")
        console.line("     Get one at \(provider.keyConsoleURL.absoluteString). It is stored in a plaintext file that only")
        console.line("     your user account can read: \(PathDisplay.tilde(layout.paths.secrets, home: layout.home)) (mode 600).")
        let saved: String?
        do {
            saved = try ctx.credentials.fileKey(for: provider)
        } catch {
            console.line("     The saved key file could not be read (\(error)); enter the key again.")
            saved = nil
        }
        let environmentKey = ctx.credentials.environment[provider.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var fallback: KeyAnswer?
        var hint: String?
        if let saved {
            fallback = KeyAnswer(value: saved, changed: false, fromEnvironment: false)
            hint = "keep \(Self.mask(saved))"
        } else if let environmentKey, !environmentKey.isEmpty {
            fallback = KeyAnswer(value: environmentKey, changed: true, fromEnvironment: true)
            hint = "use $\(provider.environmentVariable) \(Self.mask(environmentKey))"
        }
        if ctx.credentials.environmentOverrides(provider), saved != nil {
            console.line("     Note: $\(provider.environmentVariable) is set in this shell; it overrides the file for programs started from here.")
        }

        while true {
            console.write(hint.map { "     API key (typing is hidden) [\($0)]: " } ?? "     API key (typing is hidden): ")
            guard let raw = console.readSecret() else { throw endOfInput() }
            let entered = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var answer: KeyAnswer
            if entered.isEmpty {
                guard let fallback else {
                    console.line("     A key is needed. Paste it and press Enter (Ctrl-C stops setup).")
                    continue
                }
                answer = fallback
            } else {
                guard Self.plausibleKey(entered) else {
                    console.line("     That does not look like an API key (no spaces, at least 20 characters). Try again.")
                    continue
                }
                answer = KeyAnswer(value: entered, changed: entered != saved, fromEnvironment: false)
                console.line("     Received \(Self.mask(entered)).")
                if let warning = Self.prefixWarning(entered, provider: provider) { console.line("     \(warning)") }
            }
            if !answer.changed || options.skipKeyCheck { return answer }

            console.write("     Checking the key with \(provider.displayName) (lists models; no audio is sent)… ")
            switch await ctx.keyCheck(provider, answer.value) {
            case .accepted:
                console.line("accepted.")
                return answer
            case .rejected(let code):
                console.line("rejected (\(Redactor.redact(code))).")
                console.line("     Enter a valid \(provider.displayName) key.")
                if answer.fromEnvironment { fallback = saved.map { KeyAnswer(value: $0, changed: false, fromEnvironment: false) }; hint = saved.map { "keep \(Self.mask($0))" } }
            case .unreachable:
                console.line("could not reach \(provider.displayName).")
                console.line("     The key is saved as entered; it is used once the network is back.")
                return answer
            case .inconclusive(let detail):
                console.line("no clear answer (\(detail)). The key is saved as entered.")
                return answer
            }
        }
    }

    private func askSource(current: String?) throws -> URL {
        header(3, "Voice Memos recordings folder")
        let detection = ctx.detectSource()
        let defaultURL = current.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? detection.url
        switch PathProbe.directoryStatus(defaultURL) {
        case .accessible:
            console.line("     Found.")
        case .denied:
            console.line("     Found. macOS protects it; you confirm it in a macOS folder dialog in a moment.")
        case .missing, .notDirectory:
            console.line("     Not found yet. Turn on iCloud for Voice Memos on your iPhone and this Mac (same")
            console.line("     Apple Account) and open Voice Memos on the Mac once; or enter another folder.")
        }
        while true {
            let answer = try ask("     Folder", default: PathDisplay.tilde(defaultURL, home: layout.home))
            let url = PathDisplay.expand(answer, home: layout.home)
            let status = PathProbe.directoryStatus(url)
            if url.standardizedFileURL.path == defaultURL.standardizedFileURL.path {
                if status == .notDirectory { console.line("     That is a file, not a folder."); continue }
                return url
            }
            switch status {
            case .missing:
                console.line("     That folder does not exist.")
            case .notDirectory:
                console.line("     That is a file, not a folder.")
            case .denied:
                return url
            case .accessible:
                if VoiceMemosSource.looksLikeRecordingsFolder(url) { return url }
                console.line("     This does not look like a Voice Memos folder. New .m4a/.qta files that appear in it")
                console.line("     would be uploaded to your provider.")
                if try askYesNo("     Use it anyway?", default: false) { return url }
            }
        }
    }

    private func askDestination(current: String?) throws -> URL {
        header(4, "Save transcripts to")
        let defaultURL: URL
        if let current {
            defaultURL = URL(fileURLWithPath: current, isDirectory: true)
        } else {
            let proposal = ctx.proposeDestination()
            switch (proposal.kind, proposal.status) {
            case (.googleDrive, .proposed):
                console.line("     Google Drive for desktop found\(proposal.accountLabel.map { " (\($0))" } ?? ""). Files saved here sync to My Drive.")
                defaultURL = proposal.folder
            case (.googleDrive, .unresolved):
                console.line("     Google Drive is present, but its My Drive folder was not found; using Documents.")
                defaultURL = layout.home.appendingPathComponent("Documents/\(Product.transcriptsFolderName)", isDirectory: true)
            default:
                console.line("     Google Drive for desktop not found; using Documents.")
                defaultURL = proposal.folder
            }
        }
        console.line("     One .txt file per recording. The folder is created if needed; existing files are never overwritten.")
        while true {
            let answer = try ask("     Folder", default: PathDisplay.tilde(defaultURL, home: layout.home))
            let url = PathDisplay.expand(answer, home: layout.home)
            if url.standardizedFileURL.path.hasPrefix(layout.paths.root.standardizedFileURL.path) {
                console.line("     Choose a folder outside Ramble Flow's private data.")
                continue
            }
            if PathProbe.exists(url) && !PathProbe.isDirectory(url) {
                console.line("     That is a file, not a folder.")
                continue
            }
            if !PathProbe.isDirectory(url) && !PathProbe.isDirectory(url.deletingLastPathComponent()) {
                console.line("     Neither that folder nor its parent exists (\(PathDisplay.tilde(url.deletingLastPathComponent(), home: layout.home))).")
                continue
            }
            return url
        }
    }

    private func askLanguage(current: String?) throws -> String? {
        header(5, "Spoken language")
        console.line("     auto detects the language of each recording. A hint (ISO 639-1, such as en, he, es)")
        console.line("     can help when all your recordings are in one language. Speech is never translated.")
        while true {
            let answer = try ask("     Language", default: current ?? "auto").lowercased()
            if answer == "auto" { return nil }
            if answer.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil { return answer }
            console.line("     Type auto or a two-letter language code.")
        }
    }

    private func askModel(provider: ProviderID, current: String?) throws -> String? {
        header(6, "Model")
        var text = "     \(provider.displayName) default: \(provider.defaultModel)."
        if !provider.otherModels.isEmpty { text += " Also available: \(provider.otherModels.joined(separator: ", "))." }
        console.line(text)
        while true {
            let answer = try ask("     Model", default: current ?? provider.defaultModel)
            if answer.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\-]{1,80}$"#, options: .regularExpression) == nil {
                console.line("     That is not a model id.")
                continue
            }
            return answer == provider.defaultModel ? nil : answer
        }
    }

    // MARK: Folder access

    struct Access {
        var report: AccessReport
        var source: URL
        var destination: URL
    }

    /// Checks, as the background app, that it can list the recordings folder and write to the
    /// transcripts folder. Whatever is missing is granted in the native folder dialog (shown by
    /// Ramble Flow.app, already at the right folder), then checked again. Returns nil when the
    /// user canceled or access could not be established; nothing is started then.
    func grantAndVerify(source initialSource: URL, destination initialDestination: URL, configStore: ConfigStore) throws -> Access? {
        var source = initialSource
        var destination = initialDestination
        console.line("")
        console.line("Folder access")
        console.line("  Checking what Ramble Flow can access in the background…")
        var dialogsShown = 0
        while true {
            guard let report = ctx.verifier.verify() else {
                console.line("  The check could not run through launchd (see ./install.sh --status and the log).")
                return nil
            }
            describe(report)
            if report.allOK {
                return Access(report: report, source: source, destination: destination)
            }
            if report.source == .missing {
                console.line("  The recordings folder does not exist. Turn on iCloud for Voice Memos on your iPhone and")
                console.line("  this Mac (same Apple Account) and open Voice Memos on the Mac once.")
                return nil
            }
            if report.destination == .missing && !PathProbe.isDirectory(destination.deletingLastPathComponent()) {
                console.line("  The transcripts folder and its parent are not there (is Google Drive running, or the disk")
                console.line("  connected?). Fix that, or choose another folder.")
                return nil
            }
            let needSource = report.source != .ok
            let needDestination = report.destination != .ok
            if dialogsShown > 0 {
                console.line("  Access still does not work for the folder(s) above.")
                let answer = try ask("  Press Enter to show the dialog again, or q to stop", default: nil).lowercased()
                if answer == "q" || answer == "quit" { return nil }
            }
            let count = (needSource ? 1 : 0) + (needDestination ? 1 : 0)
            console.line("")
            console.line(count == 2
                ? "  Ramble Flow now shows two standard macOS folder dialogs, one after the other, each already"
                : "  Ramble Flow now shows a standard macOS folder dialog, already")
            console.line(count == 2
                ? "  showing the right folder. In each, click Grant Access."
                : "  showing the right folder. Click Grant Access.")
            if needSource { console.line("    1. \(PathDisplay.tilde(source, home: layout.home))  (read only)") }
            if needDestination {
                let shown = PathProbe.isDirectory(destination) ? destination : destination.deletingLastPathComponent()
                var line = "    \(needSource ? 2 : 1). \(PathDisplay.tilde(shown, home: layout.home))"
                if shown != destination { line += "  (a \"\(destination.lastPathComponent)\" folder is created inside)" }
                console.line(line)
            }
            console.line("  Waiting for the dialog…")
            dialogsShown += 1
            guard let outcome = ctx.granter.requestGrants(source: needSource ? source : nil, destination: needDestination ? destination : nil) else {
                console.line("  The folder dialog did not answer.")
                return nil
            }
            for (answer, label) in [(outcome.source, "Recordings folder "), (outcome.destination, "Transcripts folder")] {
                guard let answer else { continue }
                switch answer.status {
                case .granted:
                    var line = "    \(label)   granted"
                    if answer.created, let path = answer.path { line += " (created \(PathDisplay.tilde(URL(fileURLWithPath: path), home: layout.home)))" }
                    console.line(line)
                case .canceled:
                    console.line("    \(label)   canceled")
                    console.line("  You canceled the folder dialog, so nothing is uploaded and nothing was started.")
                    return nil
                case .failed:
                    console.line("    \(label)   could not be saved (\(answer.detail ?? "unknown error"))")
                    return nil
                }
            }
            // The user may have chosen another folder than the one proposed.
            if let path = outcome.source?.path, outcome.source?.status == .granted, !GrantedFolders.samePath(path, source.path) {
                source = URL(fileURLWithPath: path, isDirectory: true)
                console.line("  Recordings folder is now \(PathDisplay.tilde(source, home: layout.home)).")
                if !VoiceMemosSource.looksLikeRecordingsFolder(source) {
                    console.line("  Note: it does not look like a Voice Memos folder; new audio files in it will be uploaded.")
                }
            }
            if let path = outcome.destination?.path, outcome.destination?.status == .granted, !GrantedFolders.samePath(path, destination.path) {
                destination = URL(fileURLWithPath: path, isDirectory: true)
                console.line("  Transcripts folder is now \(PathDisplay.tilde(destination, home: layout.home)).")
            }
            let (finalSource, finalDestination) = (source, destination)
            try configStore.update {
                $0.sourcePath = finalSource.path
                $0.destinationPath = finalDestination.path
            }
            console.line("  Checking again as the background app…")
        }
    }

    private func describe(_ report: AccessReport) {
        switch report.source {
        case .ok:
            let count = report.recordings ?? 0
            console.line("    Recordings folder    ok (\(count) recording\(count == 1 ? "" : "s") there now; none of them will be uploaded)")
        case .notGranted:
            console.line("    Recordings folder    not granted yet")
        case .denied:
            console.line("    Recordings folder    no longer granted (the grant is not valid for this build)")
        case .missing:
            console.line("    Recordings folder    not found")
        }
        switch report.destination {
        case .ok:
            console.line("    Transcripts folder   ok")
        case .notGranted:
            console.line("    Transcripts folder   not granted yet")
        case .denied:
            console.line("    Transcripts folder   not writable with the current grant")
        case .missing:
            console.line("    Transcripts folder   not found")
        }
    }

    // MARK: Background process

    private func startAgent() throws {
        console.line("")
        console.line("Background process")
        let fm = FileManager.default
        try fm.createDirectory(at: layout.launchAgents, withIntermediateDirectories: true)
        let data = try LaunchAgentPlist.data(LaunchAgentPlist.make(layout: layout, extraEnvironment: LaunchAgentPlist.testEnvironment()))
        let previous = try? Data(contentsOf: layout.plist)
        let state = ctx.service.state(label: layout.label)
        let plistChanged = previous != data
        if plistChanged {
            try data.write(to: layout.plist, options: [.atomic])
            console.line("  Wrote \(PathDisplay.tilde(layout.plist, home: layout.home)) (starts at login, restarts after a crash).")
        }
        if plistChanged || options.binaryChanged || !state.running {
            try ctx.service.bootstrap(plist: layout.plist, label: layout.label)
            var after = ctx.service.state(label: layout.label)
            for _ in 0..<20 where !after.running {
                Thread.sleep(forTimeInterval: 0.25)
                after = ctx.service.state(label: layout.label)
            }
            if after.running {
                console.line("  Running\(after.pid.map { " (pid \($0))" } ?? "").")
            } else {
                console.line("  Loaded, but not running yet (last exit: \(after.lastExitStatus ?? "unknown")). See the log.")
            }
            if previous == nil {
                console.line("  macOS may show a \"Background Items Added\" notification: that is this process. If you")
                console.line("  switch it off in System Settings › General › Login Items, Ramble Flow stops.")
            }
        } else {
            console.line("  Already running\(state.pid.map { " (pid \($0))" } ?? ""); it picked up the new settings without a restart.")
        }
    }

    private func existingActivation() -> ActivationInfo? {
        guard PathProbe.exists(layout.paths.database), let store = try? JobStore(url: layout.paths.database) else { return nil }
        return (try? store.activation()) ?? nil
    }

    private func reportActivation(previous: ActivationInfo?) async {
        if let previous {
            console.line("  Watching for recordings made after \(Self.displayDate(previous.cutoff)) (kept from the first setup).")
            return
        }
        let deadline = Date().addingTimeInterval(ctx.activationTimeout)
        while Date() < deadline {
            if let info = existingActivation() {
                console.line("  Watching for recordings made after \(Self.displayDate(info.cutoff)). Older ones are never uploaded.")
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        console.line("  It has not confirmed the start yet; check with: ./install.sh --status")
    }

    // MARK: Helpers

    public static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return "••••" }
        var prefix = ""
        for candidate in ["sk-proj-", "gsk_", "sk-"] where trimmed.hasPrefix(candidate) {
            prefix = candidate
            break
        }
        return prefix + "…" + String(trimmed.suffix(4))
    }

    static func plausibleKey(_ key: String) -> Bool {
        key.count >= 20 && key.count <= 400 && !key.contains(where: { $0.isWhitespace || $0.isNewline }) && key.allSatisfy(\.isASCII)
    }

    static func prefixWarning(_ key: String, provider: ProviderID) -> String? {
        switch provider {
        case .groq where !key.hasPrefix("gsk_"): return "Groq keys usually start with gsk_; continuing anyway."
        case .openai where !key.hasPrefix("sk-"): return "OpenAI keys usually start with sk-; continuing anyway."
        default: return nil
        }
    }

    static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}
