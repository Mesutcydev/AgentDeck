//
//  CodexAppServerClient.swift
//  Shared — AgentDeck
//
//  Codex `app-server` JSON-RPC 2.0 over newline-delimited JSON on stdio.
//  Method names verified against Codex app-server docs (ADR-0013, A3).
//

import Foundation

#if os(macOS)

public enum CodexAppServerError: Error, Equatable {
    case processFailed(String)
    case protocolError(String)
    case requestTimeout(String)
    case notRunning
}

/// Minimal Codex app-server JSON-RPC client for §11.1 adapter integration.
public final class CodexAppServerClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executablePath: String
        public var workingDirectory: String
        /// Deadline applied to every JSON-RPC call so a hung agent cannot
        /// suspend the caller forever.
        public var requestTimeoutSeconds: TimeInterval

        public init(
            executablePath: String,
            workingDirectory: String,
            requestTimeoutSeconds: TimeInterval = 30
        ) {
            self.executablePath = executablePath
            self.workingDirectory = workingDirectory
            self.requestTimeoutSeconds = requestTimeoutSeconds
        }
    }

    /// Documented environment additions for Codex only: OpenAI credentials
    /// and Codex CLI config. Everything else is stripped by the allowlist.
    private static let environmentPrefixes = ["OPENAI_", "CODEX_"]

    private let configuration: Configuration
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var lineBuffer = BoundedLineBuffer()
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
    private var requestHandler: (@Sendable (Int64, String, JSONValue) -> Void)?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func setNotificationHandler(
        _ handler: @escaping @Sendable (String, JSONValue) -> Void
    ) {
        lock.lock()
        notificationHandler = handler
        lock.unlock()
    }

    public func setRequestHandler(
        _ handler: @escaping @Sendable (Int64, String, JSONValue) -> Void
    ) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
    }

    public func respond(id: Int64, result: JSONValue) throws {
        try writeLine(.object([
            ("jsonrpc", .string("2.0")),
            ("id", .int(id)),
            ("result", result)
        ]))
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = ["app-server"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workingDirectory)
        process.environment = AgentEnvironment.sanitizedForAgent(
            additionalPrefixes: Self.environmentPrefixes
        )

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let stdout = stdoutPipe.fileHandleForReading
        stdout.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }

        try process.run()
        ProcessGroupTerminator.makeGroupLeader(processIdentifier: process.processIdentifier)
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
    }

    public func stop() {
        lock.lock()
        let continuations = Array(pending.values)
        pending.removeAll()
        let process = self.process
        let stdinHandle = self.stdinHandle
        self.process = nil
        self.stdinHandle = nil
        lineBuffer.reset()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: CodexAppServerError.notRunning) }
        stdinHandle?.closeFile()
        if let process {
            ProcessGroupTerminator.terminateTree(process: process)
        }
    }

    public func call(method: String, params: JSONValue = .object([])) async throws -> JSONValue {
        let id = lock.withLock {
            let value = nextRequestID
            nextRequestID += 1
            return value
        }
        let request: JSONValue = .object([
            ("jsonrpc", .string("2.0")),
            ("id", .int(id)),
            ("method", .string(method)),
            ("params", params)
        ])
        // Deadline-based timeout: a hung agent fails the call instead of
        // leaking the continuation and suspending the caller forever.
        let timeoutNanos = UInt64(max(0.05, configuration.requestTimeoutSeconds) * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return
            }
            self?.failPending(id: id, error: CodexAppServerError.requestTimeout(method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
            do {
                try writeLine(request)
            } catch {
                failPending(
                    id: id,
                    error: (error as? CodexAppServerError) ?? .protocolError(error.localizedDescription)
                )
            }
        }
    }

    private func failPending(id: Int64, error: CodexAppServerError) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func writeLine(_ value: JSONValue) throws {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { throw CodexAppServerError.notRunning }
        let line = value.canonicalString() + "\n"
        guard let data = line.data(using: .utf8) else {
            throw CodexAppServerError.protocolError("utf8 encode failed")
        }
        try handle.write(contentsOf: data)
    }

    private func consumeStdout(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let lines = lineBuffer.append(chunk)
        lock.unlock()
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let json = try? JSONParser.parse(line) else { continue }
            handleIncoming(json)
        }
    }

    private func handleIncoming(_ json: JSONValue) {
        guard case .object(let object) = json else { return }
        if let method = object["method"]?.stringValue {
            let params = object["params"] ?? .null
            lock.lock()
            let requestHandler = self.requestHandler
            let handler = notificationHandler
            lock.unlock()
            if let id = object["id"]?.intValue {
                requestHandler?(id, method, params)
            } else {
                handler?(method, params)
            }
            return
        }
        guard let id = object["id"]?.intValue else { return }
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        guard let continuation else { return }
        if let error = object["error"] {
            continuation.resume(throwing: CodexAppServerError.protocolError(
                error.stringValue
                    ?? error.optionalField("message")?.stringValue
                    ?? error.canonicalString()
            ))
        } else if let result = object["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: CodexAppServerError.protocolError("missing result"))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

#endif
