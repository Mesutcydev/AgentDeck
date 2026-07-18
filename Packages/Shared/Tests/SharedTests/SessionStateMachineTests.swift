//
//  SessionStateMachineTests.swift
//  SharedTests — AgentDeck
//
//  §10.3 session state machine tests. The transition table is tested
//  EXHAUSTIVELY: every (from, to) activity pair is checked against the
//  normative rules — terminal states are final, `starting` is
//  initial-only, everything else flows.
//

import Foundation
import Synchronization
import Testing
@testable import Shared

@Suite("§10.3 session state machine")
struct SessionStateMachineTests {
    private let allStates = SessionActivityState.allCases
    private let terminalStates: [SessionActivityState] = [.completed, .failed, .interrupted, .terminated]
    private let workStates: [SessionActivityState] = [
        .ready, .thinking, .planning, .reading, .editing, .runningCommand,
        .runningBuild, .waitingForApproval, .waitingForUser, .runningTests
    ]

    /// The expected legality of every (from, to) pair, derived from §10.3:
    /// illegal iff target is `starting` (initial-only) or source is
    /// terminal (final). Same-state is a no-op, never a defect.
    private func expectedLegality(from: SessionActivityState, to: SessionActivityState) -> Bool {
        if from == to { return true } // no-op
        if to == .starting { return false }
        if from.isTerminal { return false }
        return true
    }

    @Test("exhaustive transition table: every (from, to) pair behaves per §10.3")
    func exhaustiveTable() {
        for from in allStates {
            for to in allStates {
                var machine = SessionStateMachine()
                // Drive the machine into `from` via a legal path.
                if from != .starting {
                    if from.isTerminal {
                        #expect(machine.transitionActivity(to: .thinking) == .applied)
                    }
                    #expect(machine.transitionActivity(to: from) == .applied)
                }
                #expect(machine.activity == from)

                let outcome = machine.transitionActivity(to: to)
                if from == to {
                    #expect(outcome == .ignoredNoOp, "\(from)→\(to) must be an ignored no-op")
                } else if expectedLegality(from: from, to: to) {
                    #expect(outcome == .applied, "\(from)→\(to) must be legal")
                    #expect(machine.activity == to)
                } else {
                    #expect(outcome == .rejectedIllegalTransition, "\(from)→\(to) must be rejected")
                    #expect(machine.activity == from, "rejected transition must not move state")
                }
            }
        }
    }

    @Test("the full §10.3 happy path runs start → work states → terminal")
    func happyPath() {
        var machine = SessionStateMachine()
        for state in workStates {
            #expect(machine.transitionActivity(to: state) == .applied)
        }
        #expect(machine.transitionActivity(to: .completed) == .applied)
    }

    @Test("starting can fail or be interrupted directly")
    func startingExits() {
        var failed = SessionStateMachine()
        #expect(failed.transitionActivity(to: .failed) == .applied)
        var interrupted = SessionStateMachine()
        #expect(interrupted.transitionActivity(to: .interrupted) == .applied)
        var completed = SessionStateMachine()
        #expect(completed.transitionActivity(to: .completed) == .applied)
    }

    @Test("terminal states are final — every exit is rejected and logged as a defect")
    func terminalIsFinal() {
        for terminal in terminalStates {
            for target in allStates where target != terminal {
                let defects = Mutex<[SessionTransitionDefect]>([])
                var machine = SessionStateMachine(defectHandler: { defect in
                    defects.withLock { $0.append(defect) }
                })
                #expect(machine.transitionActivity(to: .thinking) == .applied)
                #expect(machine.transitionActivity(to: terminal) == .applied)
                #expect(machine.transitionActivity(to: target) == .rejectedIllegalTransition)
                #expect(machine.activity == terminal)
                let recorded = defects.withLock { $0 }
                #expect(recorded.count == 1)
                #expect(recorded.first?.kind == .terminalStateIsFinal)
                #expect(recorded.first?.from == terminal)
                #expect(recorded.first?.attempted == target)
            }
        }
    }

    @Test("starting is never re-enterable")
    func startingNotReenterable() {
        let defects = Mutex<[SessionTransitionDefect]>([])
        var machine = SessionStateMachine(defectHandler: { defect in
            defects.withLock { $0.append(defect) }
        })
        #expect(machine.transitionActivity(to: .thinking) == .applied)
        #expect(machine.transitionActivity(to: .starting) == .rejectedIllegalTransition)
        #expect(defects.withLock { $0.first?.kind } == .startingNotReenterable)
    }

    @Test("connectivity is orthogonal: activity survives disconnect/reconnect")
    func connectivityOrthogonal() {
        var machine = SessionStateMachine()
        #expect(machine.transitionActivity(to: .editing) == .applied)
        #expect(machine.transitionConnectivity(to: .disconnected) == .applied)
        #expect(machine.activity == .editing, "disconnection must not change activity")
        #expect(machine.transitionConnectivity(to: .reconnecting) == .applied)
        #expect(machine.transitionConnectivity(to: .connected) == .applied)
        #expect(machine.activity == .editing)
        #expect(machine.transitionConnectivity(to: .connected) == .ignoredNoOp)
    }

    @Test("all distinct connectivity moves are legal")
    func connectivityMoves() {
        for from in SessionConnectivity.allCases {
            for to in SessionConnectivity.allCases where to != from {
                var machine = SessionStateMachine()
                // Drive to `from`.
                switch from {
                case .connected: break
                case .disconnected:
                    #expect(machine.transitionConnectivity(to: .disconnected) == .applied)
                case .reconnecting:
                    #expect(machine.transitionConnectivity(to: .reconnecting) == .applied)
                }
                #expect(machine.transitionConnectivity(to: to) == .applied,
                        "\(from)→\(to) must be legal")
            }
        }
    }
}

@Suite("§10.3 additive session states")
struct SessionStateCompletionTests {
    @Test("the state set includes ready, runningBuild, and terminated")
    func stateSetComplete() {
        #expect(SessionActivityState.allCases.contains(.ready))
        #expect(SessionActivityState.allCases.contains(.runningBuild))
        #expect(SessionActivityState.allCases.contains(.terminated))
        #expect(SessionActivityState.allCases.count == 15,
                "states are additive-only; a removal or rename breaks persisted data")
    }

    @Test("terminated is final like the other terminal states")
    func terminatedIsFinal() {
        let defects = Mutex<[SessionTransitionDefect]>([])
        var machine = SessionStateMachine(defectHandler: { defect in
            defects.withLock { $0.append(defect) }
        })
        #expect(machine.transitionActivity(to: .ready) == .applied)
        #expect(machine.transitionActivity(to: .terminated) == .applied)
        #expect(machine.transitionActivity(to: .thinking) == .rejectedIllegalTransition)
        #expect(defects.withLock { $0.first?.kind } == .terminalStateIsFinal)
    }

    @Test("ready and runningBuild are ordinary work states")
    func newWorkStatesFlow() {
        var machine = SessionStateMachine()
        #expect(machine.transitionActivity(to: .ready) == .applied)
        #expect(machine.transitionActivity(to: .runningBuild) == .applied)
        #expect(machine.transitionActivity(to: .runningTests) == .applied)
        #expect(machine.transitionActivity(to: .completed) == .applied)
    }
}
