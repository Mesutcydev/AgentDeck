//
//  PTYSupervisor.swift
//  Shared — AgentDeck
//
//  §12.4 subset: PTY creation, process lifecycle hooks, output backpressure,
//  scrollback for reattachment. macOS companion only.
//

import Foundation

#if os(macOS)
import Darwin

public enum PTYSupervisorError: Error, Equatable {
    case openPTYFailed
    case alreadyRunning
    case notRunning
    case sessionLimitReached(limit: Int)
    case launchFailed(String)
}

public struct PTYLaunchRequest: Sendable, Equatable {
    public var sessionID: SessionID
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var cols: Int
    public var rows: Int

    public init(
        sessionID: SessionID,
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = AgentEnvironment.sanitizedForAgent(),
        workingDirectory: String,
        cols: Int = 80,
        rows: Int = 24
    ) {
        self.sessionID = sessionID
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.cols = cols
        self.rows = rows
    }
}

/// §12.4 concurrent session limit (default 4, range 1–8).
public struct PTYSupervisorConfiguration: Sendable, Equatable {
    public var maxConcurrentSessions: Int

    public init(maxConcurrentSessions: Int = 4) {
        self.maxConcurrentSessions = min(8, max(1, maxConcurrentSessions))
    }
}

public struct PTYSessionSnapshot: Sendable, Equatable {
    public var sessionID: SessionID
    public var scrollback: Data
    public var isRunning: Bool
}

/// Owns one PTY child process and pumps output through backpressure +
/// scrollback. `@unchecked Sendable` is sound here because every piece of
/// mutable state is guarded by `stateLock`.
public final class PTYSession: @unchecked Sendable {
    public let sessionID: SessionID
    private let scrollback: TerminalScrollbackStore
    private let stateLock = NSLock()
    private var backpressure = TerminalBackpressureGate()
    private var masterHandle: FileHandle?
    private var process: Process?
    /// Chained scrollback writes: each append awaits the previous task so
    /// chunk order is preserved without fire-and-forget tasks.
    private var scrollbackTail: Task<Void, Never>?
    private let outputHandler: @Sendable (Data) -> Void
    private let terminationHandler: @Sendable (Int32) -> Void

    public init(
        sessionID: SessionID,
        scrollback: TerminalScrollbackStore = TerminalScrollbackStore(),
        outputHandler: @escaping @Sendable (Data) -> Void,
        terminationHandler: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.scrollback = scrollback
        self.outputHandler = outputHandler
        self.terminationHandler = terminationHandler
    }

    public func launch(_ request: PTYLaunchRequest) throws {
        stateLock.lock()
        guard process == nil else {
            stateLock.unlock()
            throw PTYSupervisorError.alreadyRunning
        }
        stateLock.unlock()

        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PTYSupervisorError.openPTYFailed
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: request.executable)
        child.arguments = request.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
        var env = request.environment
        env["TERM"] = "xterm-256color"
        env["COLUMNS"] = String(request.cols)
        env["LINES"] = String(request.rows)
        child.environment = env
        child.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        child.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        child.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        child.terminationHandler = { [weak self] proc in
            self?.stateLock.lock()
            let handle = self?.masterHandle
            self?.stateLock.unlock()
            handle?.readabilityHandler = nil
            self?.terminationHandler(proc.terminationStatus)
        }

        stateLock.lock()
        self.masterHandle = masterHandle
        self.process = child
        stateLock.unlock()
        startReading(from: masterHandle)

        do {
            try child.run()
            ProcessGroupTerminator.makeGroupLeader(processIdentifier: child.processIdentifier)
        } catch {
            stateLock.lock()
            self.masterHandle = nil
            self.process = nil
            stateLock.unlock()
            masterHandle.readabilityHandler = nil
            throw PTYSupervisorError.launchFailed(error.localizedDescription)
        }
    }

    public func sendInput(_ data: Data) {
        guard !data.isEmpty else { return }
        stateLock.lock()
        let handle = masterHandle
        stateLock.unlock()
        guard let handle else { return }
        try? handle.write(contentsOf: data)
    }

    public func resize(cols: Int, rows: Int) {
        stateLock.lock()
        let handle = masterHandle
        stateLock.unlock()
        guard let handle else { return }
        var size = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(handle.fileDescriptor, TIOCSWINSZ, &size)
    }

    public func snapshot() async -> PTYSessionSnapshot {
        PTYSessionSnapshot(
            sessionID: sessionID,
            scrollback: await scrollback.snapshot(),
            isRunning: isRunning
        )
    }

    /// TERM → grace → KILL against the whole process group, so grandchildren
    /// the agent spawned are reaped too.
    public func terminate(graceMillis: Int = 2_000) {
        stateLock.lock()
        let process = self.process
        stateLock.unlock()
        guard let process, process.isRunning else { return }
        ProcessGroupTerminator.terminateTree(process: process, graceMillis: graceMillis)
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process?.isRunning ?? false
    }

    private func startReading(from handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fh in
            guard let self else {
                fh.readabilityHandler = nil
                return
            }
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            let now = Date.unixMillisecondsNow
            self.stateLock.lock()
            let action = self.backpressure.evaluate(count: chunk.count, now: now)
            self.stateLock.unlock()
            switch action {
            case .accept:
                self.enqueueScrollback(chunk)
                self.outputHandler(chunk)
            case .drop(let dropped):
                if dropped < chunk.count {
                    let accepted = Data(chunk.prefix(chunk.count - dropped))
                    self.enqueueScrollback(accepted)
                    self.outputHandler(accepted)
                }
            }
        }
    }

    /// Serialized scrollback writes: each append is chained behind the
    /// previous one under `stateLock`, preserving chunk order.
    private func enqueueScrollback(_ chunk: Data) {
        stateLock.lock()
        let tail = scrollbackTail
        scrollbackTail = Task { [scrollback] in
            await tail?.value
            do {
                try await scrollback.append(chunk)
            } catch {
                Log.logger(.adapter).error(
                    "PTY scrollback append failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        stateLock.unlock()
    }
}

/// Supervises multiple PTY sessions with the §12.4 concurrent limit.
public actor PTYSupervisor {
    private let configuration: PTYSupervisorConfiguration
    private var sessions: [SessionID: PTYSession] = [:]

    public init(configuration: PTYSupervisorConfiguration = PTYSupervisorConfiguration()) {
        self.configuration = configuration
    }

    public func launch(
        _ request: PTYLaunchRequest,
        outputHandler: @escaping @Sendable (Data) -> Void,
        terminationHandler: @escaping @Sendable (Int32) -> Void = { _ in }
    ) throws -> PTYSession {
        guard sessions[request.sessionID] == nil else {
            throw PTYSupervisorError.alreadyRunning
        }
        let active = sessions.values.filter(\.isRunning).count
        guard active < configuration.maxConcurrentSessions else {
            throw PTYSupervisorError.sessionLimitReached(limit: configuration.maxConcurrentSessions)
        }
        let session = PTYSession(
            sessionID: request.sessionID,
            outputHandler: outputHandler,
            terminationHandler: { [weak self] status in
                terminationHandler(status)
                Task { await self?.removeSession(request.sessionID) }
            }
        )
        try session.launch(request)
        sessions[request.sessionID] = session
        return session
    }

    public func session(for id: SessionID) -> PTYSession? {
        sessions[id]
    }

    public func sendInput(sessionID: SessionID, data: Data) throws {
        guard let session = sessions[sessionID] else { throw PTYSupervisorError.notRunning }
        session.sendInput(data)
    }

    public func snapshot(sessionID: SessionID) async throws -> PTYSessionSnapshot {
        guard let session = sessions[sessionID] else { throw PTYSupervisorError.notRunning }
        return await session.snapshot()
    }

    public func terminate(sessionID: SessionID) {
        sessions[sessionID]?.terminate()
    }

    public func removeSession(_ id: SessionID) {
        sessions[id] = nil
    }

    public var activeSessionCount: Int {
        sessions.values.filter(\.isRunning).count
    }
}
#endif
