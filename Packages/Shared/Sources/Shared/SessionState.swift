//
//  SessionState.swift
//  Shared — AgentDeck
//
//  §10.3 session state machine. Activity states:
//  starting → ready | thinking | planning | reading | editing |
//  runningCommand | runningBuild | waitingForApproval | waitingForUser |
//  runningTests → completed | failed | interrupted | terminated — plus
//  orthogonal connectivity (disconnected / reconnecting). Illegal
//  transitions are rejected and reported as adapter defects, never
//  silently applied. States are additive-only on the wire so older
//  persisted values always decode.
//

import Foundation

/// Activity states of an agent session (SPEC §10.3).
public enum SessionActivityState: String, Sendable, CaseIterable, Codable {
    /// Initial state of every session; never re-entered.
    case starting
    /// Launch finished; the session is idle and ready for prompts.
    case ready
    case thinking
    case planning
    case reading
    case editing
    case runningCommand
    case runningBuild
    case waitingForApproval
    case waitingForUser
    case runningTests
    /// Terminal states — final; nothing leaves them.
    case completed
    case failed
    case interrupted
    /// The agent process ended without a structured completion (e.g. the
    /// provider exited); equally final as the other terminal states.
    case terminated

    /// Work states per §10.3 (everything between starting and terminal).
    public static let workStates: Set<SessionActivityState> = [
        .ready, .thinking, .planning, .reading, .editing, .runningCommand,
        .runningBuild, .waitingForApproval, .waitingForUser, .runningTests
    ]

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .interrupted || self == .terminated
    }

    /// The explicit legal-transition table (§10.3). This is the single
    /// authority; `SessionStateMachine` consults it and the exhaustive
    /// transition test pins every (from, to) pair against it.
    ///
    /// Rules:
    ///  - `starting` may move to any work state or any terminal state
    ///    (launch failure → failed, cancel during launch → interrupted,
    ///    trivial task → completed).
    ///  - Any work state may move to any other work state (agents freely
    ///    interleave thinking/planning/reading/editing/commands/tests and
    ///    waits) or to any terminal state.
    ///  - Terminal states are final.
    ///  - `starting` is initial-only and is never a legal target.
    public func canTransition(to target: SessionActivityState) -> Bool {
        if target == .starting { return false }
        if isTerminal { return false }
        return true
    }
}

/// Orthogonal connectivity axis (§10.3). Independent of activity: a session
/// keeps its activity state while the device link drops and recovers.
/// iPhone disconnection never kills a session (§12.4).
public enum SessionConnectivity: String, Sendable, CaseIterable, Codable {
    case connected
    case disconnected
    case reconnecting

    public func canTransition(to target: SessionConnectivity) -> Bool {
        // All moves between distinct connectivity states are legal;
        // a same-state transition is an ignored no-op, not a defect.
        target != self
    }
}

/// Outcome of a transition request.
public enum SessionTransitionOutcome: Sendable, Equatable {
    /// State changed.
    case applied
    /// Same-state request — ignored, not a defect.
    case ignoredNoOp
    /// Illegal transition — rejected, logged as an adapter defect (§10.3).
    case rejectedIllegalTransition
}

/// An illegal transition attempt, reported as an adapter defect (§10.3).
public struct SessionTransitionDefect: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case terminalStateIsFinal
        case startingNotReenterable
    }

    public let from: SessionActivityState
    public let attempted: SessionActivityState
    public let kind: Kind

    public init(from: SessionActivityState, attempted: SessionActivityState, kind: Kind) {
        self.from = from
        self.attempted = attempted
        self.kind = kind
    }
}

/// The §10.3 state machine. Value type; the session owner (companion,
/// Phase 2+) holds it inside an actor. Illegal transitions are rejected
/// and reported through `defectHandler` (wired to logging by the owner).
public struct SessionStateMachine: Sendable {
    public private(set) var activity: SessionActivityState
    public private(set) var connectivity: SessionConnectivity
    private let defectHandler: @Sendable (SessionTransitionDefect) -> Void

    public init(
        defectHandler: @escaping @Sendable (SessionTransitionDefect) -> Void = { _ in }
    ) {
        self.activity = .starting
        self.connectivity = .connected
        self.defectHandler = defectHandler
    }

    /// Requests an activity transition. Returns the outcome; illegal
    /// transitions leave the state unchanged and are reported as defects.
    @discardableResult
    public mutating func transitionActivity(to target: SessionActivityState) -> SessionTransitionOutcome {
        guard target != activity else { return .ignoredNoOp }
        guard activity.canTransition(to: target) else {
            defectHandler(SessionTransitionDefect(
                from: activity,
                attempted: target,
                kind: activity.isTerminal ? .terminalStateIsFinal : .startingNotReenterable
            ))
            return .rejectedIllegalTransition
        }
        activity = target
        return .applied
    }

    /// Requests a connectivity transition (orthogonal axis, §10.3).
    @discardableResult
    public mutating func transitionConnectivity(to target: SessionConnectivity) -> SessionTransitionOutcome {
        guard target != connectivity else { return .ignoredNoOp }
        connectivity = target
        return .applied
    }
}
