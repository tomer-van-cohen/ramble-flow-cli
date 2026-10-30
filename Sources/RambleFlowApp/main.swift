// The executable of Ramble Flow.app: sandboxed, no UI except the native folder dialog.
//
//   RambleFlow run --support-dir DIR --log-dir DIR          background work (started by launchd)
//   RambleFlow probe-access --support-dir DIR --output FILE  what this sandboxed app can access
//   RambleFlow grant --support-dir DIR [--source DIR] [--destination DIR]
//                                                            folder dialog(s), then exit
//
// Opened any other way (double-click in Finder), it does nothing and quits.
import Darwin
import Foundation
import RambleFlowCLI
import RambleFlowCore

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func supportPaths() -> AppPaths? {
    guard let root = value("--support-dir") else { return nil }
    let logs = value("--log-dir") ?? URL(fileURLWithPath: root).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Logs/\(Product.supportFolderName)").path
    return AppPaths(root: URL(fileURLWithPath: root, isDirectory: true), logs: URL(fileURLWithPath: logs, isDirectory: true))
}

switch arguments.first {
case "run":
    guard let paths = supportPaths() else {
        fputs("usage: RambleFlow run --support-dir DIR --log-dir DIR\n", stderr)
        exit(2)
    }
    exit(await Daemon.run(paths: paths))
case "probe-access":
    guard let paths = supportPaths(), let output = value("--output") else {
        fputs("usage: RambleFlow probe-access --support-dir DIR --output FILE\n", stderr)
        exit(2)
    }
    exit(AccessProbe.write(AccessProbe.run(paths: paths), to: URL(fileURLWithPath: output)) ? 0 : 1)
case "grant":
    guard let paths = supportPaths() else {
        fputs("usage: RambleFlow grant --support-dir DIR [--source DIR] [--destination DIR]\n", stderr)
        exit(2)
    }
    let request = GrantRequest(
        paths: paths,
        source: value("--source").map { URL(fileURLWithPath: $0, isDirectory: true) },
        destination: value("--destination").map { URL(fileURLWithPath: $0, isDirectory: true) },
        testMode: arguments.contains("--test-auto") ? .auto : (arguments.contains("--test-cancel") ? .cancel : nil))
    GrantUI.run(request)
default:
    exit(0)
}
