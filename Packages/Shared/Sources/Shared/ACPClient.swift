//
//  ACPClient.swift
//  Shared — AgentDeck
//
//  Zed-lineage Agent Client Protocol (ACP) JSON-RPC 2.0 over NDJSON stdio.
//  Used by Kimi and OpenCode adapters (ADR-0005, ADR-0017).
//

import Foundation

#if os(macOS)

public enum ACPClientError: Error, Equatable {
    case processFailed(String)
    case protocolError(String)
    case requestTimeout(String)
    case notRunning
}

extension ACPClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .processFailed(let detail):
            "The provider CLI exited during launch: \(detail)"
        case .protocolError(let detail):
            "The provider returned an invalid ACP response: \(detail)"
        case .requestTimeout(let method):
            "The provider did not answer \(method) in time. Check the CLI on your Mac and retry."
        case .notRunning:
            "The provider CLI is not running. Start a new provider session."
        }
    }
}

/// Minimal ACP client for §11.1 adapter integration.
public final class ACPClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var executablePath: String
        public var launchArguments: [String]
        public var workingDirectory: String
        public var protocolVersion: Int
        /// Deadline applied to every JSON-RPC call so a hung agent cannot
        /// suspend the caller forever.
        public var requestTimeoutSeconds: TimeInterval

        public init(
            executablePath: String,
            launchArguments: [String],
            workingDirectory: String,
            protocolVersion: Int = 1,
            requestTimeoutSeconds: TimeInterval = 30
        ) {
            self.executablePath = executablePath
            self.launchArguments = launchArguments
            self.workingDirectory = workingDirectory
            self.protocolVersion = protocolVersion
            self.requestTimeoutSeconds = requestTimeoutSeconds
        }
    }

    public enum IncomingMessage: Sendable {
        case notification(method: String, params: JSONValue)
        case request(id: Int64, method: String, params: JSONValue)
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID: Int64 = 1
    private var pending: [Int64: CheckedContinuation<JSONValue, Error>] = [:]
    private var lineBuffer = BoundedLineBuffer()
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
    private var requestHandler: (@Sendable (Int64, String, JSONValue) -> Void)?

    /// Documented environment additions for ACP agents: Kimi/Moonshot
    /// credentials, OpenCode config, and the two provider families OpenCode
    /// brokers (OpenAI, Anthropic). Everything else is stripped.
    private static let environmentPrefixes = [
        "MOONSHOT_",
        "KIMI_",
        "OPENCODE_",
        "OPENAI_",
        "ANTHROPIC_"
    ]

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

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.launchArguments
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

        continuations.forEach { $0.resume(throwing: ACPClientError.notRunning) }
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
        try writeLine(request)

        // Deadline-based timeout: a hung agent fails the call instead of
        // leaking the continuation and suspending the caller forever.
        let timeoutNanos = UInt64(max(0.05, configuration.requestTimeoutSeconds) * 1_000_000_000)
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanos)
            } catch {
                return
            }
            self?.failPending(id: id, error: ACPClientError.requestTimeout(method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending[id] = continuation
            lock.unlock()
        }
    }

    private func failPending(id: Int64, error: ACPClientError) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    public func respond(id: Int64, result: JSONValue) throws {
        let response: JSONValue = .object([
            ("jsonrpc", .string("2.0")),
            ("id", .int(id)),
            ("result", result)
        ])
        try writeLine(response)
    }

    public func initialize(clientName: String = "AgentDeck", clientVersion: String = "1.0") async throws -> JSONValue {
        try await call(
            method: "initialize",
            params: .object([
                ("protocolVersion", .int(Int64(configuration.protocolVersion))),
                ("clientCapabilities", .object([]))
            ])
        )
    }

    public func sessionNew(cwd: String) async throws -> String {
        let result = try await call(
            method: "session/new",
            params: .object([("cwd", .string(cwd))])
        )
        guard case .object(let entries) = result,
              let sessionID = entries["sessionId"]?.stringValue ?? entries["sessionID"]?.stringValue else {
            throw ACPClientError.protocolError("missing sessionId")
        }
        return sessionID
    }

    private func writeLine(_ value: JSONValue) throws {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { throw ACPClientError.notRunning }
        let line = value.canonicalString() + "\n"
        guard let data = line.data(using: .utf8) else {
            throw ACPClientError.protocolError("utf8 encode failed")
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
            if let id = object["id"]?.intValue {
                lock.lock()
                let handler = requestHandler
                lock.unlock()
                handler?(id, method, params)
            } else {
                lock.lock()
                let handler = notificationHandler
                lock.unlock()
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
            continuation.resume(throwing: ACPClientError.protocolError(
                error.stringValue ?? "rpc error"
            ))
        } else if let result = object["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: ACPClientError.protocolError("missing result"))
        }
    }
}

#endif
