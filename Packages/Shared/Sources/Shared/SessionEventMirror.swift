//
//  SessionEventMirror.swift
//  Shared — AgentDeck
//
//  Persists remote session.event frames into a local SessionRepository
//  (iOS cache of Mac-originated timeline data).
//

import Foundation

public enum SessionEventMirrorError: Error, Equatable {
    case invalidAgentIdentifier(String)
}

/// Mirrors Mac-originated agent events into a local store without rebroadcast.
public struct SessionEventMirror: Sendable {
    private let repository: any SessionRepository

    public init(repository: any SessionRepository) {
        self.repository = repository
    }

    public func mirror(_ event: AgentEvent) async throws {
        try await ensureSessionExists(for: event)
        let record = EventRecord(
            id: event.id,
            sessionID: event.sessionID,
            sequence: event.sequence,
            timestamp: event.timestamp,
            confidence: event.confidence,
            kind: event.payload.kind,
            payload: event.payload.toJSONValue()
        )
        do {
            try await repository.insertEvent(record)
        } catch RepositoryError.conflict, RepositoryError.constraintViolation {
            // Idempotent replay after resume — ignore duplicate sequences.
            return
        }

        switch event.payload {
        case .approvalRequested(let request):
            if try await repository.approvals(sessionID: event.sessionID)
                .contains(where: { $0.request.id == request.id && $0.isPending }) {
                return
            }
            try await repository.insertApproval(ApprovalRecord(request: request))
            try await updateSessionState(event.sessionID, state: .waitingForApproval)
        case .approvalResolved(let resolution):
            try await repository.recordApprovalDecision(
                requestID: resolution.requestID,
                decision: resolution.decision,
                resolvedAt: resolution.decision.decidedAt
            )
            try await updateSessionState(event.sessionID, state: .thinking)
        case .completed(let result):
            try await updateSessionState(
                event.sessionID,
                state: .completed,
                completionSummary: result.summary
            )
        case .failed:
            try await updateSessionState(event.sessionID, state: .failed)
        case .stateChanged(let change):
            try await updateSessionState(event.sessionID, state: change.to)
        default:
            break
        }
    }

    private func ensureSessionExists(for event: AgentEvent) async throws {
        if try await repository.session(id: event.sessionID) != nil {
            return
        }
        let now = event.timestamp
        try await repository.insertSession(
            SessionRecord(
                id: event.sessionID,
                agent: event.agent,
                state: .starting,
                createdAt: now,
                updatedAt: now
            )
        )
    }

    private func updateSessionState(
        _ sessionID: SessionID,
        state: SessionActivityState,
        completionSummary: String? = nil
    ) async throws {
        let now = Date.unixMillisecondsNow
        try await repository.updateSessionState(
            id: sessionID,
            state: state,
            updatedAt: now,
            endedAt: state.isTerminal ? now : nil,
            completionSummary: completionSummary
        )
    }
}
