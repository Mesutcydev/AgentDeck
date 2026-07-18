import SwiftUI
import Shared

struct SessionMemoryView: View {
    let state: AppState
    @State private var selection: SessionID?
    @State private var query = ""

    private var sessions: [SessionRecord] {
        guard !query.isEmpty else { return state.recentSessions }
        return state.recentSessions.filter { session in
            let theme = CompanionProviderTheme.resolve(session.agent)
            let project = session.projectID.flatMap { state.projectsByID[$0]?.displayName } ?? ""
            return theme.name.localizedCaseInsensitiveContains(query)
                || project.localizedCaseInsensitiveContains(query)
                || session.completionSummary?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    CompanionSectionLabel(index: "01", title: "Session memory")
                    Spacer()
                    Text("\(state.recentSessions.count)")
                        .font(CompanionDeckFont.label)
                        .foregroundStyle(CompanionDeckColor.muted)
                }
                .padding(16)
                .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }

                if sessions.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No sessions yet" : "No matching sessions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(query.isEmpty ? "Real agent sessions will be retained here automatically." : "Try a provider or project name.")
                    )
                } else {
                    List(sessions, id: \.id, selection: $selection) { session in
                        SessionMemoryRow(state: state, session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete Session", role: .destructive) {
                                    Task { await state.deleteSession(session) }
                                }
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CompanionDeckColor.canvas)
            .searchable(text: $query, placement: .sidebar, prompt: "Search memory")
            .navigationSplitViewColumnWidth(min: 290, ideal: 330)
        } detail: {
            if let selection,
               let session = state.recentSessions.first(where: { $0.id == selection }) {
                SessionMemoryDetail(state: state, session: session)
                    .id(session.id)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    CompanionPageHeader(
                        index: "02",
                        title: "Session memory",
                        detail: "A durable record of real agent work, stored locally on this Mac. Select a session to inspect its state and redacted event ledger."
                    )
                    Spacer()
                }
                .padding(30)
                .background(CompanionDeckColor.canvas)
            }
        }
        .task { await state.refreshStatus() }
        .preferredColorScheme(.light)
    }
}

private struct SessionMemoryRow: View {
    let state: AppState
    let session: SessionRecord

    var body: some View {
        let theme = CompanionProviderTheme.resolve(session.agent)
        HStack(spacing: 12) {
            CompanionProviderMark(agent: session.agent, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(theme.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Circle().fill(session.state.isTerminal ? CompanionDeckColor.muted : theme.accent).frame(width: 6, height: 6)
                }
                Text(session.projectID.flatMap { state.projectsByID[$0]?.displayName } ?? "Unscoped session")
                    .font(CompanionDeckFont.mono)
                    .foregroundStyle(CompanionDeckColor.muted)
                    .lineLimit(1)
                Text(Date(timeIntervalSince1970: Double(session.updatedAt) / 1000), style: .relative)
                    .font(.caption2.monospaced())
                    .foregroundStyle(CompanionDeckColor.muted)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct SessionMemoryDetail: View {
    let state: AppState
    let session: SessionRecord
    @State private var events: [EventRecord] = []

    var body: some View {
        let theme = CompanionProviderTheme.resolve(session.agent)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 16) {
                    CompanionProviderMark(agent: session.agent, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.name).font(CompanionDeckFont.title)
                        Text(projectName)
                            .font(CompanionDeckFont.mono)
                            .foregroundStyle(CompanionDeckColor.muted)
                    }
                    Spacer()
                    Text(session.state.rawValue.uppercased())
                        .font(CompanionDeckFont.label)
                        .foregroundStyle(theme.accent)
                }
                .padding(.bottom, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }

                HStack(spacing: 12) {
                    metric("STARTED", session.createdAt)
                    metric("UPDATED", session.updatedAt)
                    metric("EVENTS", Int64(events.count), isDate: false)
                }

                if let summary = session.completionSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        CompanionSectionLabel(index: "01", title: "Completion")
                        Text(summary).font(.system(size: 15)).textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    CompanionSectionLabel(index: "02", title: "Event ledger")
                        .padding(.bottom, 10)
                    if events.isEmpty {
                        Text("No retained events for this session.")
                            .font(CompanionDeckFont.body)
                            .foregroundStyle(CompanionDeckColor.muted)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(events, id: \.id) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(format: "%03llu", event.sequence))
                                    .font(CompanionDeckFont.label)
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 38, alignment: .leading)
                                Text(event.kind.uppercased())
                                    .font(CompanionDeckFont.label)
                                Spacer()
                                Text(Date(timeIntervalSince1970: Double(event.timestamp) / 1000), style: .time)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(CompanionDeckColor.muted)
                            }
                            .padding(.vertical, 9)
                            .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
                        }
                    }
                }
            }
            .padding(30)
        }
        .background(CompanionDeckColor.canvas)
        .task { events = await state.events(for: session.id) }
    }

    private func metric(_ title: String, _ value: Int64, isDate: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(CompanionDeckFont.label).foregroundStyle(CompanionDeckColor.muted)
            Text(isDate ? Date(timeIntervalSince1970: Double(value) / 1000).formatted(date: .abbreviated, time: .shortened) : "\(value)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionDeckColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
    }

    private var projectName: String {
        guard let projectID = session.projectID else { return "Unscoped session" }
        return state.projectsByID[projectID]?.displayName ?? "Unscoped session"
    }
}
