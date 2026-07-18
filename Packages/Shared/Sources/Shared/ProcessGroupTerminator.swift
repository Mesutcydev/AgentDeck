//
//  ProcessGroupTerminator.swift
//  Shared — AgentDeck
//
//  Process-tree termination for agent subprocesses. Signalling only the
//  direct child leaves grandchildren (build tools, test runners, servers the
//  agent spawned) alive; every agent child is made a process-group leader so
//  the whole tree can be signalled with kill(-pgid, …) and a
//  SIGTERM → grace → SIGKILL escalation.
//

import Foundation

#if os(macOS)
import Darwin

public enum ProcessGroupTerminator {
    /// Best-effort promotion of a freshly launched child to process-group
    /// leader. Must be called immediately after `Process.run()`.
    ///
    /// Documented race: Foundation offers no pre-exec hook, so a child that
    /// spawns grandchildren in the tiny window before this call may leave
    /// them outside the group. `EPERM`/`ESRCH` failures (child already
    /// exec'd into its own session, or already exited) are tolerated — the
    /// subsequent group signal simply falls back to the direct pid.
    @discardableResult
    public static func makeGroupLeader(processIdentifier: Int32) -> Bool {
        setpgid(processIdentifier, processIdentifier) == 0
    }

    /// Signals the whole process group; falls back to the direct pid when
    /// no group with that id exists (leader never promoted or already gone).
    public static func signalTree(processIdentifier: Int32, _ signal: Int32) {
        if kill(-processIdentifier, signal) != 0 {
            kill(processIdentifier, signal)
        }
    }

    /// SIGTERM the tree, then SIGKILL anything still alive after the grace
    /// period. `isRunning` reports whether the leader process is still up.
    public static func terminateTree(
        processIdentifier: Int32,
        graceMillis: Int = 2_000,
        isRunning: @escaping @Sendable () -> Bool
    ) {
        signalTree(processIdentifier: processIdentifier, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(graceMillis)) {
            guard isRunning() else { return }
            signalTree(processIdentifier: processIdentifier, SIGKILL)
        }
    }

    /// `terminateTree` convenience for a Foundation `Process`.
    public static func terminateTree(process: Process, graceMillis: Int = 2_000) {
        guard process.isRunning else { return }
        terminateTree(processIdentifier: process.processIdentifier, graceMillis: graceMillis) { [weak process] in
            process?.isRunning ?? false
        }
    }
}
#endif
