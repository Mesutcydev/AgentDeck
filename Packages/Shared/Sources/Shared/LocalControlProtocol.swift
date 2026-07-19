import Foundation

/// Local, user-only control protocol used by the bundled `agentdeck` CLI.
/// It is deliberately separate from the paired-device wire protocol.
public enum LocalControlCommand: String, Codable, Sendable {
    case status
    case open
    case run
    case sessions
    case attach
    case discoverImports
    case importSession
    case doctor
    case interrupt
    case detach
}

public struct LocalControlRequest: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let maximumEncodedBytes = 64 * 1024

    public var version: Int
    public var id: UUID
    public var command: LocalControlCommand
    public var provider: String?
    public var projectPath: String?
    public var sessionID: String?
    public var externalSessionID: String?
    public var arguments: [String]

    public init(
        version: Int = currentVersion,
        id: UUID = UUID(),
        command: LocalControlCommand,
        provider: String? = nil,
        projectPath: String? = nil,
        sessionID: String? = nil,
        externalSessionID: String? = nil,
        arguments: [String] = []
    ) {
        self.version = version
        self.id = id
        self.command = command
        self.provider = provider
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.externalSessionID = externalSessionID
        self.arguments = arguments
    }
}

public struct LocalSessionSummary: Codable, Sendable, Equatable {
    public var id: String
    public var provider: String
    public var projectPath: String?
    public var state: String
    public var origin: String
    public var updatedAt: Int64

    public init(id: String, provider: String, projectPath: String?, state: String, origin: String, updatedAt: Int64) {
        self.id = id
        self.provider = provider
        self.projectPath = projectPath
        self.state = state
        self.origin = origin
        self.updatedAt = updatedAt
    }
}

public enum ExternalSessionProcessState: String, Codable, Sendable {
    case active
    case inactive
    case unknown
}

public struct ExternalSessionDescriptor: Codable, Sendable, Equatable, Identifiable {
    public var providerID: String
    public var externalSessionID: String
    public var projectPath: String?
    public var updatedAt: Int64
    public var compatibilityVersion: String?
    public var processState: ExternalSessionProcessState
    public var canResume: Bool

    public init(
        providerID: String,
        externalSessionID: String,
        projectPath: String?,
        updatedAt: Int64,
        compatibilityVersion: String? = nil,
        processState: ExternalSessionProcessState = .unknown,
        canResume: Bool
    ) {
        self.providerID = providerID
        self.externalSessionID = externalSessionID
        self.projectPath = projectPath
        self.updatedAt = updatedAt
        self.compatibilityVersion = compatibilityVersion
        self.processState = processState
        self.canResume = canResume
    }

    public var id: String { "\(providerID):\(externalSessionID)" }
}

public struct LocalControlResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var requestID: UUID
    public var ok: Bool
    public var message: String
    public var sessionID: String?
    public var streamFollows: Bool
    public var sessions: [LocalSessionSummary]
    public var imports: [ExternalSessionDescriptor]

    public init(
        requestID: UUID,
        ok: Bool,
        message: String,
        sessionID: String? = nil,
        streamFollows: Bool = false,
        sessions: [LocalSessionSummary] = [],
        imports: [ExternalSessionDescriptor] = []
    ) {
        self.version = LocalControlRequest.currentVersion
        self.requestID = requestID
        self.ok = ok
        self.message = message
        self.sessionID = sessionID
        self.streamFollows = streamFollows
        self.sessions = sessions
        self.imports = imports
    }
}

/// Versioned packets used after a successful `run` or `attach` response.
/// Terminal bytes remain opaque and are encoded by Codable as base64.
public struct LocalTerminalMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case input
        case output
        case resize
        case interrupt
        case detach
        case error
    }

    public var version: Int
    public var kind: Kind
    public var data: Data?
    public var columns: Int?
    public var rows: Int?
    public var message: String?

    public init(
        version: Int = LocalControlRequest.currentVersion,
        kind: Kind,
        data: Data? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.kind = kind
        self.data = data
        self.columns = columns
        self.rows = rows
        self.message = message
    }
}

public enum LocalControlPath {
    public static func socketURL(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        let currentHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if homeDirectory.standardizedFileURL == currentHome.standardizedFileURL,
           let override = ProcessInfo.processInfo.environment["AGENTDECK_CONTROL_SOCKET"],
           override.hasPrefix("/") {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory
            .appendingPathComponent("Library/Application Support/AgentDeck", isDirectory: true)
            .appendingPathComponent("control.sock")
    }
}
