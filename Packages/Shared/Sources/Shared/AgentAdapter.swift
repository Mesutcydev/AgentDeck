//
//  AgentAdapter.swift
//  Shared — AgentDeck
//
//  §10.1 adapter protocol and §10.2 input types. The iPhone never talks
//  to agent protocols directly — the Mac companion implements adapters
//  (Constitution #9).
//

import Foundation

/// Input sent to a running agent session (§10.2).
public enum AgentInput: Sendable, Equatable {
    case prompt(PromptInput)
}

/// A running session plus its structured event stream (§10.1).
public struct AgentSessionStream: Sendable {
    public let handle: AgentSessionHandle
    public let events: AsyncStream<AgentEvent>

    public init(handle: AgentSessionHandle, events: AsyncStream<AgentEvent>) {
        self.handle = handle
        self.events = events
    }
}

public enum ExternalSessionUnsupportedReason: String, Codable, Sendable, Equatable {
    case notImplemented
    case incompatibleProvider
    case incompatibleVersion
}

public enum ExternalSessionCapability: Sendable, Equatable {
    case supported
    case unsupported(ExternalSessionUnsupportedReason)
}

public struct ExternalSessionCapabilities: Sendable, Equatable {
    public var discovery: ExternalSessionCapability
    public var importing: ExternalSessionCapability

    public init(discovery: ExternalSessionCapability, importing: ExternalSessionCapability) {
        self.discovery = discovery
        self.importing = importing
    }

    public static let unsupported = ExternalSessionCapabilities(
        discovery: .unsupported(.notImplemented),
        importing: .unsupported(.notImplemented)
    )
}

/// §10.1 — swappable agent integration boundary.
public protocol AgentAdapter: Sendable {
    var identifier: AgentIdentifier { get }
    var capabilities: AgentCapabilities { get }
    var externalSessionCapabilities: ExternalSessionCapabilities { get }

    func inspectInstallation() async -> AgentInstallation
    func inspectAuthentication() async -> AgentAuthenticationState

    func launch(configuration: AgentLaunchConfiguration) async throws -> AgentSessionStream
    func send(_ input: AgentInput, to session: AgentSessionHandle) async throws
    func resolveApproval(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        in session: AgentSessionHandle
    ) async throws
    func interrupt(session: AgentSessionHandle) async throws
    func resume(session: AgentSessionHandle) async throws
    func terminate(session: AgentSessionHandle) async throws
}

public extension AgentAdapter {
    var externalSessionCapabilities: ExternalSessionCapabilities { .unsupported }
}
