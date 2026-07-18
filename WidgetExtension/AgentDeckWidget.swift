//
//  AgentDeckWidget.swift
//  WidgetExtension — AgentDeck
//
//  §18 optional status widget — summary only, no supervision.
//  Deep links route into the app: agentdeck://home, //approvals, and
//  (handled app-side) //session/<id>.
//

import SwiftUI
import WidgetKit
import Shared

/// Deep-link targets the widget can point at. `//session/<id>` needs a
/// session identifier the summary deliberately does not carry; the app
/// still handles it for notification deep links.
enum AgentDeckDeepLink {
    static let home = URL(string: "agentdeck://home")
    static let approvals = URL(string: "agentdeck://approvals")

    static func session(_ id: SessionID) -> URL? {
        URL(string: "agentdeck://session/\(id.wireString)")
    }
}

struct AgentDeckWidgetEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummaryState.Summary?
}

struct AgentDeckWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentDeckWidgetEntry {
        AgentDeckWidgetEntry(
            date: .now,
            summary: WidgetSummaryState.Summary(
                connectedMacName: "Mac",
                activeSessionCount: 1,
                pendingApprovalCount: 0,
                lastCompletedSessionSummary: nil,
                connectionStatus: "Connected"
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentDeckWidgetEntry) -> Void) {
        completion(AgentDeckWidgetEntry(date: .now, summary: WidgetSummaryState.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentDeckWidgetEntry>) -> Void) {
        let entry = AgentDeckWidgetEntry(date: .now, summary: WidgetSummaryState.read())
        let timeline = Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300)))
        completion(timeline)
    }
}

struct AgentDeckWidgetEntryView: View {
    let entry: AgentDeckWidgetEntry
    @Environment(\.widgetFamily) private var family

    /// Whole-widget target: approvals when something needs attention.
    private var primaryDeepLink: URL? {
        if (entry.summary?.pendingApprovalCount ?? 0) > 0 {
            return AgentDeckDeepLink.approvals
        }
        return AgentDeckDeepLink.home
    }

    var body: some View {
        switch family {
        case .systemMedium, .systemLarge, .systemExtraLarge:
            mediumBody
        default:
            smallBody
                .widgetURL(primaryDeepLink)
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.summary?.connectedMacName ?? "AgentDeck")
                .font(.headline)
                .lineLimit(1)
            Text(entry.summary?.connectionStatus ?? "Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Label("\(entry.summary?.activeSessionCount ?? 0)", systemImage: "terminal")
                Label("\(entry.summary?.pendingApprovalCount ?? 0)", systemImage: "checkmark.shield")
            }
            .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// Medium family supports per-element Links (never mixed with widgetURL).
    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.summary?.connectedMacName ?? "AgentDeck")
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.summary?.connectionStatus ?? "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = entry.summary?.lastCompletedSessionSummary, !last.isEmpty {
                    Text(last)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if let home = AgentDeckDeepLink.home {
                    Link(destination: home) {
                        Label("\(entry.summary?.activeSessionCount ?? 0)", systemImage: "terminal")
                            .font(.caption)
                    }
                }
                if let approvals = AgentDeckDeepLink.approvals {
                    Link(destination: approvals) {
                        Label("\(entry.summary?.pendingApprovalCount ?? 0)", systemImage: "checkmark.shield")
                            .font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AgentDeckWidget: Widget {
    let kind = "AgentDeckStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgentDeckWidgetProvider()) { entry in
            AgentDeckWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AgentDeck Status")
        .description("Connected Mac, sessions, and pending approvals.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
