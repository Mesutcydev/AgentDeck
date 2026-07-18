//
//  WidgetSummaryState.swift
//  Shared — AgentDeck
//
//  §18 sanitized widget summary via App Group (no secrets, no supervision).
//

import Foundation

public enum WidgetSummaryState {
    public static let appGroupIdentifier = "group.com.agentdeck.shared"
    public static let summaryKey = "widget.summary.v1"

    public struct Summary: Sendable, Codable, Equatable {
        public var connectedMacName: String?
        public var activeSessionCount: Int
        public var pendingApprovalCount: Int
        public var lastCompletedSessionSummary: String?
        public var connectionStatus: String
        public var updatedAt: Int64

        public init(
            connectedMacName: String?,
            activeSessionCount: Int,
            pendingApprovalCount: Int,
            lastCompletedSessionSummary: String?,
            connectionStatus: String,
            updatedAt: Int64 = Date.unixMillisecondsNow
        ) {
            self.connectedMacName = connectedMacName
            self.activeSessionCount = activeSessionCount
            self.pendingApprovalCount = pendingApprovalCount
            self.lastCompletedSessionSummary = lastCompletedSessionSummary
            self.connectionStatus = connectionStatus
            self.updatedAt = updatedAt
        }
    }

    public static func write(_ summary: Summary) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = try? JSONEncoder().encode(summary) else { return }
        defaults.set(data, forKey: summaryKey)
    }

    public static func read() -> Summary? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: summaryKey) else { return nil }
        return try? JSONDecoder().decode(Summary.self, from: data)
    }
}
