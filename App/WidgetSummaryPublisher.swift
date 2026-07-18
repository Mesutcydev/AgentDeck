//
//  WidgetSummaryPublisher.swift
//  App — AgentDeck
//
//  Writes sanitized widget summary state to the App Group (§18).
//  Free-text fields pass through the Shared Redactor and are length-capped
//  so no secret material ever reaches the widget surface (Constitution #8).
//

import Foundation
import Shared

enum WidgetSummaryPublisher {
    /// Cap for any free-text field handed to the widget.
    private static let summaryCharacterCap = 200

    static func publish(
        connectedMacName: String?,
        sessions: [SessionRecord],
        pendingApprovalCount: Int,
        connectionStatus: String
    ) {
        let activeCount = sessions.filter { $0.isActive }.count
        let lastCompleted = sessions
            .filter { $0.state == .completed }
            .sorted { ($0.endedAt ?? $0.updatedAt) > ($1.endedAt ?? $1.updatedAt) }
            .first?
            .completionSummary
            .map(sanitize)
        WidgetSummaryState.write(
            WidgetSummaryState.Summary(
                connectedMacName: connectedMacName,
                activeSessionCount: activeCount,
                pendingApprovalCount: pendingApprovalCount,
                lastCompletedSessionSummary: lastCompleted,
                connectionStatus: connectionStatus
            )
        )
    }

    /// Redacts secret shapes (bearer tokens, API keys, PEM blocks, key=value
    /// credentials) and caps length before text leaves the app process.
    private static func sanitize(_ text: String) -> String {
        let redacted = Redactor.redact(text)
        guard redacted.count > summaryCharacterCap else { return redacted }
        return String(redacted.prefix(summaryCharacterCap))
    }
}
