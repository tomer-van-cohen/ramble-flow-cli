import Darwin
import Foundation

/// The terminal, abstracted so the setup dialog can be driven by tests.
public protocol Console: AnyObject {
    func write(_ text: String)
    /// One line without its newline; nil at end of input.
    func readLine() -> String?
    /// One line without echo when the input is a terminal; nil at end of input.
    func readSecret() -> String?
    /// Whether colors/emphasis may be used.
    var isInteractive: Bool { get }
}

public extension Console {
    func line(_ text: String = "") { write(text + "\n") }
}

public final class StandardConsole: Console {
    public init() {}

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    public func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    /// Turns terminal echo off while reading. Ctrl-C restores the terminal before exiting.
    public func readSecret() -> String? {
        guard isatty(STDIN_FILENO) == 1 else { return Swift.readLine(strippingNewline: true) }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return Swift.readLine(strippingNewline: true) }
        var silent = original
        silent.c_lflag &= ~tcflag_t(ECHO)
        silent.c_lflag |= tcflag_t(ECHONL)
        TerminalRestore.saved = original
        signal(SIGINT) { _ in
            if var saved = TerminalRestore.saved { tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
            _ = Darwin.write(STDOUT_FILENO, "\n", 1)
            _exit(130)
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &silent)
        let value = Swift.readLine(strippingNewline: true)
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        TerminalRestore.saved = nil
        signal(SIGINT, SIG_DFL)
        return value
    }
}

enum TerminalRestore {
    nonisolated(unsafe) static var saved: termios?
}

/// A console fed from a list of lines, recording everything written (tests).
public final class ScriptedConsole: Console {
    private var inputs: [String]
    public private(set) var output = ""
    public var isInteractive: Bool { false }

    public init(_ inputs: [String]) {
        self.inputs = inputs
    }

    public func write(_ text: String) { output += text }

    public func readLine() -> String? {
        guard !inputs.isEmpty else { return nil }
        let value = inputs.removeFirst()
        output += value + "\n"
        return value
    }

    public func readSecret() -> String? {
        guard !inputs.isEmpty else { return nil }
        let value = inputs.removeFirst()
        output += "\n"
        return value
    }

    public var remainingInputs: Int { inputs.count }
}
