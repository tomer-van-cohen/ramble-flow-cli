import Darwin
import Foundation

/// Process-level exclusion for the background worker: whoever holds the lock file runs the worker.
/// A second copy of the app (or a stale launch) cannot process the same recordings in parallel.
/// The lock is released automatically when the process exits, including after a crash.
public final class WorkerLock {
    private var descriptor: Int32 = -1

    public init() {}

    deinit { release() }

    public var isHeld: Bool { descriptor >= 0 }

    /// Non-blocking. Returns false if another process (or another open of the file) holds it.
    public func acquire(at url: URL) -> Bool {
        guard descriptor < 0 else { return true }
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
