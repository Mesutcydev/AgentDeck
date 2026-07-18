//
//  Logging.swift
//  Shared — AgentDeck
//
//  Thin OSLog front-end (SPEC §25: OSLog with privacy annotations).
//  Subsystem derives from ProductNaming (§2); one Logger per category.
//  The API returns os.Logger directly because OSLog privacy annotations
//  only exist at the interpolation call site — forwarding a pre-built
//  message would flatten them. Call sites annotate explicitly:
//    Log.logger(.wire).info("frame \(type, privacy: .public) seq \(seq, privacy: .public)")
//  Unannotated interpolations default to OSLog's private redaction — the
//  desired safe default; secrets never reach logs (Constitution #8) and
//  producers scrub payloads with `Redactor` before logging them.
//

import Foundation
import OSLog

/// Per-area log categories for the shared package and its consumers.
public enum LogCategory: String, Sendable, CaseIterable {
    /// §9 wire protocol: frames, signatures, seq/ack, replay.
    case wire
    /// Session lifecycle and §10.3 state machine.
    case session
    /// Approval requests, decisions, idempotent resolution.
    case approval
    /// Security events: signature failures, replays, redaction, pairing.
    case security
    /// Transport connectivity (Phase 3).
    case transport
    /// Agent adapters (Phase 6+).
    case adapter
    /// Metrics and signposts.
    case metrics
}

/// Category loggers for the shared subsystem. No stored state — Logger
/// construction is cheap (OSLog caches backing stores internally), so
/// there is no global mutable singleton here (§25).
public enum Log {
    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: ProductNaming.logSubsystem, category: category.rawValue)
    }
}
