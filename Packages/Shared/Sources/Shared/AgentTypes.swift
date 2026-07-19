//
//  AgentTypes.swift
//  Shared — AgentDeck
//
//  §10.2 common types used across adapters and apps: installation state,
//  authentication state, capabilities, launch configuration, session
//  handle, prompt input, attachment. Provider-agnostic; adapters (Phase 6+)
//  map their vendor specifics onto these. These types are not on the wire
//  yet — wire serialization is added, versioned, when a frame needs them.
//

import Foundation

/// Whether the agent's executable is present and runnable (§10.2, §22).
public enum AgentInstallationState: Sendable, Equatable {
    case notInstalled
    case installed(version: String)
    case broken(reason: String)
}

/// Result of inspecting an agent installation (§10.2, §12.3).
public struct AgentInstallation: Sendable, Equatable {
    public let state: AgentInstallationState
    /// Canonical path of the detected executable, when found (§12.3).
    public let executablePath: String?

    public init(state: AgentInstallationState, executablePath: String? = nil) {
        self.state = state
        self.executablePath = executablePath
    }
}

/// §10.2, §22: provider authentication is always resolved on the Mac —
/// credentials never flow through the iOS side.
public enum AgentAuthenticationState: Sendable, Equatable {
    case unknown
    case authenticated
    case authenticationRequired
    case expired
}

/// What an adapter can do (§10.2). Unsupported capabilities degrade
/// visibly, never silently (§29 Phase 11).
public struct AgentCapabilities: Sendable, Equatable {
    public let structuredEvents: Bool
    public let approvals: Bool
    public let sessionResume: Bool
    public let cancellation: Bool
    public let streaming: Bool

    public init(
        structuredEvents: Bool,
        approvals: Bool,
        sessionResume: Bool,
        cancellation: Bool,
        streaming: Bool
    ) {
        self.structuredEvents = structuredEvents
        self.approvals = approvals
        self.sessionResume = sessionResume
        self.cancellation = cancellation
        self.streaming = streaming
    }
}

/// §10.2 launch configuration for a new agent session.
public struct AgentLaunchConfiguration: Sendable, Equatable {
    public let sessionID: SessionID
    public let projectID: ProjectID
    /// Canonical working directory inside an authorized project (§12.4, §16).
    public let workingDirectory: String
    public let initialPrompt: PromptInput?
    /// Provider model selector, when the user picked one (§11.1).
    public let model: String?
    public let origin: SessionOrigin
    public let providerSessionReference: ProviderSessionReference?

    public init(
        sessionID: SessionID = .random(),
        projectID: ProjectID,
        workingDirectory: String,
        initialPrompt: PromptInput? = nil,
        model: String? = nil,
        origin: SessionOrigin = .iosLaunch,
        providerSessionReference: ProviderSessionReference? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.workingDirectory = workingDirectory
        self.initialPrompt = initialPrompt
        self.model = model
        self.origin = origin
        self.providerSessionReference = providerSessionReference
    }
}

/// Handle to a running agent session (§10.2).
public struct AgentSessionHandle: Sendable, Equatable, Identifiable {
    public let sessionID: SessionID
    public let agent: AgentIdentifier

    public init(sessionID: SessionID, agent: AgentIdentifier) {
        self.sessionID = sessionID
        self.agent = agent
    }

    public var id: SessionID { sessionID }
}

/// §10.2 prompt input: text plus attachments (sent per §16.2 rules).
public struct PromptInput: Sendable, Equatable {
    public let text: String
    public let attachments: [AttachmentReference]

    public init(text: String, attachments: [AttachmentReference] = []) {
        self.text = text
        self.attachments = attachments
    }
}

/// §10.2 attachment reference. The companion owns temp-file lifecycle and
/// hands agents only safe local paths (§16.2); filenames are never
/// interpolated into shell commands.
public struct AttachmentReference: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Sanitized, unique display filename (§16.2 safe filename rules).
    public let fileName: String
    public let byteCount: Int64
    public let mimeType: String?

    public init(id: UUID = UUID(), fileName: String, byteCount: Int64, mimeType: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.byteCount = byteCount
        self.mimeType = mimeType
    }
}
