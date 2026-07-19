//
//  SessionsListView.swift
//  App — AgentDeck
//
//  §29 sessions tab (DESIGN §7.3): themed rows, state chips, swipe-to-stop
//  on live sessions. Every session opens the session detail surface.
//

import SwiftUI
import Shared

extension SessionActivityState {
    /// User-facing label; future states (ready, runningBuild, terminated)
    /// render as their raw value rather than breaking the build.
    var displayName: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking"
        case .planning: "Planning"
        case .reading: "Reading"
        case .editing: "Editing"
        case .runningCommand: "Running Command"
        case .waitingForApproval: "Waiting for Approval"
        case .waitingForUser: "Waiting for You"
        case .runningTests: "Running Tests"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        default: rawValue.capitalized
        }
    }

    var compactDisplayName: String {
        switch self {
        case .waitingForApproval: "Approval"
        case .waitingForUser: "Waiting"
        case .runningCommand: "Running"
        case .runningTests: "Tests"
        default: displayName
        }
    }
}

struct SessionsListView: View {
    private enum Filter: String, CaseIterable { case active = "Active", completed = "Completed", failed = "Failed", pinned = "Pinned" }
    @Bindable var state: IOSAppState
    @State private var path: [SessionID] = []
    @State private var searchText = ""
    @State private var filter: Filter = .active

    private var matchingSessions: [SessionRecord] {
        guard !searchText.isEmpty else { return state.sessions }
        return state.sessions.filter { session in
            let provider = AgentCatalog.descriptor(for: session.agent)?.displayName ?? session.agent.rawValue
            return provider.localizedCaseInsensitiveContains(searchText)
                || projectName(for: session)?.localizedCaseInsensitiveContains(searchText) == true
                || session.completionSummary?.localizedCaseInsensitiveContains(searchText) == true
                || session.state.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredSessions: [SessionRecord] {
        switch filter {
        case .active: matchingSessions.filter(\.isActive)
        case .completed: matchingSessions.filter { $0.state == .completed }
        case .failed: matchingSessions.filter { $0.state.isTerminal && $0.state != .completed }
        case .pinned: []
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                DeckPageHeader(
                    index: "02",
                    title: "Sessions",
                    detail: "Live and completed agent work, ordered by most recent activity."
                )
                .listRowInsets(EdgeInsets(top: 0, leading: DeckSpace.m, bottom: 12, trailing: DeckSpace.m))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                SessionSummaryStrip(
                    running: state.sessions.filter(\.isActive).count,
                    completed: state.sessions.filter { $0.state == .completed }.count,
                    failed: state.sessions.filter { $0.state.isTerminal && $0.state != .completed }.count
                )
                .listRowInsets(EdgeInsets(top: 0, leading: DeckSpace.m, bottom: DeckSpace.s, trailing: DeckSpace.m))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Picker("Session filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 8, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filteredSessions.isEmpty {
                    VStack(alignment: .leading, spacing: DeckSpace.xs) {
                        Text(searchText.isEmpty ? "00 / NO SESSIONS" : "00 / NO MATCHES")
                            .font(DeckFont.monoSmall.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "Start an agent from Home or mirror a running session from your Mac." : "Try a provider, project, state, or completion summary.")
                            .font(DeckFont.callout)
                    }
                    .padding(.vertical, DeckSpace.l)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section {
                        sessionRows(filteredSessions, isMemory: filter != .active)
                    } header: {
                        DeckSectionLabel(title: filter.rawValue, eyebrow: "Mission log", systemImage: filter == .active ? "waveform.path.ecg" : "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { DeckCanvas() }
            .tint(DeckColor.accent)
            .searchable(text: $searchText, prompt: "Search session memory")
            .navigationDestination(for: SessionID.self) { sessionID in
                if let session = state.sessions.first(where: { $0.id == sessionID }) {
                    SessionView(
                        state: state,
                        session: session,
                        model: state.terminalModel(for: session.id)
                    )
                } else {
                    ContentUnavailableView(
                        "Session Unavailable",
                        systemImage: "terminal",
                        description: Text("This session is not in the local mirror yet.")
                    )
                }
            }
            .task {
                await state.refreshSessions()
                // Cold-start race: a deep link that arrived before this tab
                // existed still has its session pending — consume it here,
                // not only in onChange.
                if let sessionID = state.consumeDeepLinkSession() {
                    path = [sessionID]
                }
            }
            .refreshable { await state.refreshSessions() }
            .onChange(of: state.deepLinkNonce) {
                if let sessionID = state.consumeDeepLinkSession() {
                    path = [sessionID]
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRows(_ sessions: [SessionRecord], isMemory: Bool) -> some View {
        ForEach(sessions, id: \.id) { session in
            NavigationLink(value: session.id) {
                SessionRow(session: session, projectName: projectName(for: session), showsSummary: isMemory)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: DeckSpace.m, bottom: 0, trailing: DeckSpace.m))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing) {
                if !session.state.isTerminal {
                    Button(role: .destructive) {
                        DeckHaptics.warning()
                        Task { await state.interruptSession(sessionID: session.id) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        DeckHaptics.warning()
                        Task { await state.deleteSession(session) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func projectName(for session: SessionRecord) -> String? {
        guard let projectID = session.projectID else { return nil }
        return state.projects.first(where: { $0.id == projectID })?.displayName
    }
}

/// §7.3 row: 28 pt themed glyph chip, project (or agent) title, state
/// chip tinted by the agent accent while live.
private struct SessionRow: View {
    let session: SessionRecord
    let projectName: String?
    var showsSummary = false

    private var theme: AgentTheme {
        AgentThemes.theme(for: session.agent)
    }

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            ProviderMark(theme: theme, size: 30, isLive: !session.state.isTerminal)
            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                Text(projectName ?? agentDisplayName)
                    .font(DeckFont.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                HStack(spacing: DeckSpace.xxs) {
                    HStack(spacing: DeckSpace.xxs) {
                        Text(agentDisplayName)
                        Text("·")
                        Text(updatedDate, style: .relative)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    Spacer(minLength: DeckSpace.xs)
                    StateChip(state: session.state, accent: theme.accent, compact: true)
                }
                .font(DeckFont.footnote)
                .foregroundStyle(.secondary)
                if showsSummary, let summary = session.completionSummary, !summary.isEmpty {
                    Text(summary)
                        .font(DeckFont.footnote)
                        .foregroundStyle(DeckColor.ink.opacity(0.58))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, DeckSpace.s)
        .padding(.vertical, DeckSpace.xs + 2)
        .frame(minHeight: 70)
        .background(DeckColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous)
                .stroke(DeckColor.rule, lineWidth: 0.75)
        }
        .accessibilityElement(children: .combine)
    }

    private var agentDisplayName: String {
        AgentCatalog.descriptor(for: session.agent)?.displayName ?? session.agent.rawValue
    }

    private var updatedDate: Date {
        Date(timeIntervalSince1970: Double(session.updatedAt) / 1_000)
    }
}

private struct SessionSummaryStrip: View {
    let running: Int
    let completed: Int
    let failed: Int

    var body: some View {
        HStack(spacing: 0) {
            SessionSummaryMetric(value: running, label: "Running", tint: DeckColor.activity)
            SessionSummaryMetric(value: completed, label: "Finished", tint: DeckColor.success)
            SessionSummaryMetric(value: failed, label: "Failed", tint: DeckColor.danger)
        }
        .padding(DeckSpace.s)
        .background(DeckColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous)
                .stroke(DeckColor.rule, lineWidth: 0.75)
        }
    }
}

private struct SessionSummaryMetric: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(DeckFont.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
