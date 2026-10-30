import AppKit
import Foundation
import RambleFlowCLI
import RambleFlowCore

struct GrantRequest {
    enum TestMode { case auto, cancel }

    var paths: AppPaths
    var source: URL?
    var destination: URL?
    /// Test-hooks builds only: answer without showing a dialog.
    var testMode: TestMode?
}

/// The only UI Ramble Flow has: the standard macOS folder dialog, once per folder that needs a
/// grant, already showing the right folder. The app stays an accessory (no Dock icon, no menu
/// bar item) and quits as soon as the dialogs are answered.
enum GrantUI {
    static func run(_ request: GrantRequest) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            let outcome = perform(request)
            GrantRecorder.write(outcome, to: request.paths.grantResult)
            exit(0)
        }
        app.run()
        exit(0)
    }

    static func perform(_ request: GrantRequest) -> GrantOutcome {
        let grants = GrantStore(url: request.paths.grants)
        var outcome = GrantOutcome()
        if let source = request.source {
            guard let picked = pick(
                at: source,
                message: "Ramble Flow needs to read your Voice Memos recordings. This folder is already selected: click Grant Access.",
                canCreate: false, request: request)
            else {
                outcome.source = .init(status: .canceled)
                return outcome
            }
            outcome.source = GrantRecorder.recordSource(picked: picked, grants: grants)
        }
        if let destination = request.destination {
            let start = PathProbe.isDirectory(destination) ? destination : destination.deletingLastPathComponent()
            let message = PathProbe.isDirectory(destination)
                ? "Ramble Flow saves a text file here for each new recording. Click Grant Access."
                : "Ramble Flow will create a \"\(destination.lastPathComponent)\" folder here for your transcripts. Click Grant Access."
            guard let picked = pick(at: start, message: message, canCreate: true, request: request) else {
                outcome.destination = .init(status: .canceled)
                return outcome
            }
            outcome.destination = GrantRecorder.recordDestination(picked: picked, intended: destination, grants: grants)
        }
        return outcome
    }

    static func pick(at folder: URL, message: String, canCreate: Bool, request: GrantRequest) -> URL? {
        #if RAMBLE_FLOW_TEST_HOOKS
        switch request.testMode {
        case .auto: return folder
        case .cancel: return nil
        case nil: break
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Ramble Flow"
        panel.message = message
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreate
        panel.showsHiddenFiles = false
        panel.directoryURL = folder
        panel.level = .floating
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
