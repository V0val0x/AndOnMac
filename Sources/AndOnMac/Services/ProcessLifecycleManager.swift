import Foundation
import Darwin

/// Centralized supervisor for all child `Process` instances (`scrcpy`, `adb`, audio, recording, app windows).
/// Guarantees clean `SIGTERM` -> `SIGKILL` termination on window close, timeout, or app quit (`applicationWillTerminate`)
/// so zero zombie or orphan processes remain.
public final class ProcessLifecycleManager: @unchecked Sendable {
    public static let shared = ProcessLifecycleManager()

    private struct TrackedProcess {
        let process: Process
        let tag: String
    }

    private let lock = NSLock()
    private var tracked: [UUID: TrackedProcess] = [:]

    private init() {}

    /// Registers a running (or about-to-run) `Process` and automatically unregisters it when it exits.
    @discardableResult
    public func register(_ process: Process, tag: String) -> UUID {
        let id = UUID()
        let previousHandler = process.terminationHandler
        process.terminationHandler = { [weak self] proc in
            self?.unregister(id)
            previousHandler?(proc)
        }
        lock.lock()
        tracked[id] = TrackedProcess(process: process, tag: tag)
        lock.unlock()
        return id
    }

    /// Removes a process from the active registry.
    public func unregister(_ id: UUID) {
        lock.lock()
        tracked.removeValue(forKey: id)
        lock.unlock()
    }

    /// Returns the number of currently tracked running processes (useful for diagnostics & tests).
    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        tracked = tracked.filter { $0.value.process.isRunning }
        return tracked.count
    }

    /// Terminates a single process gracefully with `SIGTERM`, escalating to `SIGKILL` after `gracePeriodMs` if still alive.
    /// Never blocks the caller's thread.
    public func terminateProcess(_ process: Process, gracePeriodMs: UInt64 = 350) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
            if process.isRunning && pid > 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Terminates all tracked processes matching `tag` (`SIGTERM` -> `SIGKILL` fallback).
    public func terminateProcesses(withTag tag: String, gracePeriodMs: UInt64 = 350) {
        lock.lock()
        let matches = tracked.filter { $0.value.tag == tag }
        for key in matches.keys {
            tracked.removeValue(forKey: key)
        }
        lock.unlock()

        for (_, entry) in matches {
            terminateProcess(entry.process, gracePeriodMs: gracePeriodMs)
        }
    }

    /// Terminates every tracked child process. Pass `synchronousWait: true` during `applicationWillTerminate`
    /// so macOS does not exit before `SIGKILL` cleans up stubborn subprocesses.
    public func terminateAllProcesses(synchronousWait: Bool = false, gracePeriodMs: UInt64 = 250) {
        lock.lock()
        let all = Array(tracked.values)
        tracked.removeAll()
        lock.unlock()

        let running = all.map(\.process).filter { $0.isRunning }
        guard !running.isEmpty else { return }

        for proc in running {
            proc.terminate()
        }

        if synchronousWait {
            let deadline = Date().addingTimeInterval(Double(gracePeriodMs) / 1000.0)
            while Date() < deadline {
                if running.allSatisfy({ !$0.isRunning }) {
                    return
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            for proc in running where proc.isRunning {
                let pid = proc.processIdentifier
                if pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(Int(gracePeriodMs))) {
                for proc in running where proc.isRunning {
                    let pid = proc.processIdentifier
                    if pid > 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    }
}
