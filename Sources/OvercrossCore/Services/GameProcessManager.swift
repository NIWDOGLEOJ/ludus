import Foundation

public final class GameProcessManager: @unchecked Sendable {
    public static let shared = GameProcessManager()

    private let lock = NSLock()
    private var activeProcesses: [pid_t: ProcessInfoRecord] = [:]
    private var frozenPIDs: Set<pid_t> = []

    public struct ProcessInfoRecord: Sendable {
        public let pid: pid_t
        public let gameTitle: String
        public let process: Process
        public let launchedAt: Date

        public init(pid: pid_t, gameTitle: String, process: Process, launchedAt: Date = Date()) {
            self.pid = pid
            self.gameTitle = gameTitle
            self.process = process
            self.launchedAt = launchedAt
        }
    }

    public init() {}

    public func register(process: Process, gameTitle: String) {
        lock.lock()
        defer { lock.unlock() }
        let pid = process.processIdentifier
        if pid > 0 {
            activeProcesses[pid] = ProcessInfoRecord(
                pid: pid,
                gameTitle: gameTitle,
                process: process,
                launchedAt: Date()
            )
        }
    }

    public func unregister(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        activeProcesses.removeValue(forKey: pid)
        frozenPIDs.remove(pid)
    }

    @discardableResult
    public func freezeProcess(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeProcesses[pid] != nil else { return false }
        if kill(pid, SIGSTOP) == 0 {
            frozenPIDs.insert(pid)
            return true
        }
        return false
    }

    @discardableResult
    public func thawProcess(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeProcesses[pid] != nil else { return false }
        if kill(pid, SIGCONT) == 0 {
            frozenPIDs.remove(pid)
            return true
        }
        return false
    }

    public func isFrozen(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return frozenPIDs.contains(pid)
    }

    public func activeGamePIDs() -> [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeProcesses.keys)
    }

    public func record(for pid: pid_t) -> ProcessInfoRecord? {
        lock.lock()
        defer { lock.unlock() }
        return activeProcesses[pid]
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        activeProcesses.removeAll()
        frozenPIDs.removeAll()
    }
}
