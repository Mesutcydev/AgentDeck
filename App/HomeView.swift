//
//  HomeView.swift
//  App — AgentDeck
//
//  §17 Home tab (DESIGN §7.2): greeting + one-line connection status,
//  themed agent grid, active sessions, and the two primary actions
//  (New Session / New Shell) on native glass.
//

import SwiftUI
import Shared

struct HomeView: View {
    @Bindable var state: IOSAppState
    @State private var isPresentingNewSession = false
    @State private var isPresentingNewShell = false
    @State private var path: [SessionID] = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isConnected: Bool {
        state.remoteConnectionStatus.hasPrefix("Connected")
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.xl) {
                    header
                    agentGrid
                    activeSessions
                    quickActions
                    if let sessionError = state.error(for: .session) {
                        Label(sessionError, systemImage: "exclamationmark.triangle.fill")
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }
                .padding(.horizontal, DeckSpace.m)
                .padding(.vertical, DeckSpace.l)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background { DeckCanvas() }
            .tint(DeckColor.accent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { EmptyView() } }
            .refreshable { await refreshAll() }
            .sheet(isPresented: $isPresentingNewSession) {
                NewSessionSheet(state: state)
            }
            .sheet(isPresented: $isPresentingNewShell) {
                NewShellSheet(state: state) { sessionID in
                    isPresentingNewShell = false
                    if let sessionID {
                        path = [sessionID]
                    }
                }
            }
            .navigationDestination(for: SessionID.self) { sessionID in
                if let session = state.sessions.first(where: { $0.id == sessionID }) {
                    SessionView(
                        state: state,
                        session: session,
                        model: state.terminalModel(for: sessionID)
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
                await state.refreshProjects()
            }
        }
    }

    // MARK: - Header (§7.2)

    private var header: some View {
        VStack(alignment: .leading, spacing: DeckSpace.m) {
            HStack(alignment: .center, spacing: DeckSpace.s) {
                DeckMark(size: 34, color: DeckColor.ink, showsSignal: false)
                HStack(spacing: 0) {
                    Text("AGENT").foregroundStyle(DeckColor.ink)
                    Text("/DECK").foregroundStyle(DeckColor.accent)
                }
                .font(DeckFont.display)
                .tracking(-1.4)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DeckSpace.s) {
                    connectionStatus
                    pendingApprovalStatus
                }
                VStack(alignment: .leading, spacing: DeckSpace.xs) {
                    connectionStatus
                    pendingApprovalStatus
                }
            }
            .padding(.vertical, DeckSpace.s)
            .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
            .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
            if state.connectionCircuitOpen {
                Button {
                    DeckHaptics.retry()
                    Task { await state.retryConnections() }
                } label: {
                    Label("Reconnect Now", systemImage: "arrow.clockwise")
                        .font(DeckFont.callout.weight(.semibold))
                }
                .buttonStyle(.glass)
                .padding(.top, DeckSpace.xxs)
            }
            if let connectionError = state.error(for: .connection), !state.connectionCircuitOpen {
                Text(connectionError)
                    .font(DeckFont.footnote)
                    .foregroundStyle(DeckColor.danger)
            }
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: DeckSpace.xs) {
            Circle()
                .fill(isConnected ? DeckColor.success : Color(.tertiaryLabel))
                .frame(width: 8, height: 8)
            Text(state.remoteConnectionStatus)
                .font(DeckFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var pendingApprovalStatus: some View {
        if !state.pendingApprovalRecords.isEmpty {
            Label(
                "\(state.pendingApprovalRecords.count) waiting",
                systemImage: "checkmark.shield.fill"
            )
            .font(DeckFont.monoSmall.weight(.semibold))
            .foregroundStyle(DeckColor.warning)
            .fixedSize()
            .accessibilityLabel(
                "\(state.pendingApprovalRecords.count) approval\(state.pendingApprovalRecords.count == 1 ? "" : "s") waiting"
            )
        }
    }

    // MARK: - Agent grid (§7.2)

    private var agentColumns: [GridItem] {
        let count = horizontalSizeClass == .regular ? 4 : 2
        return Array(repeating: GridItem(.flexible(), spacing: DeckSpace.s), count: count)
    }

    @ViewBuilder
    private var agentGrid: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            DeckSectionLabel(
                title: "Your agents",
                eyebrow: "Connected tools",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            if state.agentCards.isEmpty {
                VStack(alignment: .leading, spacing: DeckSpace.s) {
                    Text("01")
                        .font(DeckFont.monoSmall)
                        .foregroundStyle(DeckColor.accent)
                    Text("One transcript.\nEvery coding agent.")
                        .font(DeckFont.headline)
                        .tracking(-0.4)
                    Text("Pair a Mac to bring Claude Code, Codex, Grok, Kimi, OpenCode, and shell sessions into the same remote workspace.")
                        .font(DeckFont.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DeckSpace.l)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
                .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
            } else {
                VStack(spacing: 0) {
                    ForEach(state.agentCards) { card in
                        AgentCardCell(card: card)
                            .transition(DeckMotion.appearance(reduceMotion: reduceMotion))
                    }
                }
                .animation(DeckMotion.standard, value: state.agentCards)
            }
        }
    }

    // MARK: - Active sessions (§7.2)

    @ViewBuilder
    private var activeSessions: some View {
        if !state.activeSessions.isEmpty {
            VStack(alignment: .leading, spacing: DeckSpace.s) {
                DeckSectionLabel(
                    title: "Live conversations",
                    eyebrow: "In progress",
                    systemImage: "bubble.left.and.text.bubble.right.fill"
                )
                VStack(spacing: DeckSpace.xs) {
                    ForEach(state.activeSessions, id: \.id) { session in
                        Button {
                            path = [session.id]
                        } label: {
                            ActiveSessionRow(session: session, projectName: projectName(for: session))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func projectName(for session: SessionRecord) -> String? {
        guard let projectID = session.projectID else { return nil }
        return state.projects.first(where: { $0.id == projectID })?.displayName
    }

    // MARK: - Quick actions (§7.2)

    private var quickActions: some View {
        HStack(spacing: DeckSpace.s) {
            Button {
                isPresentingNewSession = true
            } label: {
                Label("Start Agent", systemImage: "sparkles")
                    .font(DeckFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(DeckActionButtonStyle(primary: true))
            .disabled(!isConnected)

            Button {
                isPresentingNewShell = true
            } label: {
                Label("New Shell", systemImage: "terminal")
                    .font(DeckFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(DeckActionButtonStyle())
            .disabled(!isConnected)
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: isPresentingNewSession) { _, new in
            new
        }
    }

    private func refreshAll() async {
        await state.refreshDevices()
        await state.refreshSessions()
        await state.refreshProjects()
        await state.refreshApprovalState()
    }
}

// MARK: - Agent card cell (§7.2: 96 pt, radius 14, padding 12)

private struct AgentCardCell: View {
    let card: IOSAppState.AgentCard

    private var theme: AgentTheme {
        AgentThemes.theme(for: card.id)
    }

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            ProviderMark(theme: theme, size: 24, isLive: card.activeSessionCount > 0)
                .saturation(card.isObservedInstalled ? 1 : 0)
                .opacity(card.isObservedInstalled ? 1 : 0.35)
            Text(card.displayName)
                .font(DeckFont.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text(statusLine)
                .font(DeckFont.monoSmall)
                .foregroundStyle(card.activeSessionCount > 0 ? theme.accent : Color.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, DeckSpace.s)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.displayName), \(statusLine)")
    }

    private var statusLine: String {
        if card.activeSessionCount > 0 {
            "\(card.activeSessionCount) active"
        } else if card.isObservedInstalled {
            card.version.map { "v\($0)" } ?? "Installed"
        } else {
            "Not observed"
        }
    }
}

// MARK: - Active session row (§7.2: 3 pt accent leading edge + state chip)

private struct ActiveSessionRow: View {
    let session: SessionRecord
    let projectName: String?

    private var theme: AgentTheme {
        AgentThemes.theme(for: session.agent)
    }

    var body: some View {
        HStack(spacing: DeckSpace.s) {
            ProviderMark(theme: theme, size: 22, isLive: !session.state.isTerminal)
            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                Text(projectName ?? session.agent.rawValue)
                    .font(DeckFont.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(agentDisplayName)
                    .font(DeckFont.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            StateChip(state: session.state, accent: theme.accent)
        }
        .padding(.horizontal, DeckSpace.s)
        .padding(.vertical, DeckSpace.xs + 2)
        .background(DeckColor.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
    }

    private var agentDisplayName: String {
        AgentCatalog.descriptor(for: session.agent)?.displayName ?? session.agent.rawValue
    }
}

/// Session state chip: agent-accented while live, monochrome when terminal.
struct StateChip: View {
    let state: SessionActivityState
    let accent: Color
    var compact = false

    var body: some View {
        Text(compact ? state.compactDisplayName : state.displayName)
            .font(DeckFont.monoSmall.weight(.medium))
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(state.isTerminal ? Color.secondary : accent)
    }
}

// MARK: - New Shell sheet (project picker → terminal.start)

private struct NewShellSheet: View {
    @Bindable var state: IOSAppState
    let onStarted: (SessionID?) -> Void
    @State private var startingProjectID: ProjectID?

    var body: some View {
        NavigationStack {
            List {
                if state.projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects Synced",
                        systemImage: "folder",
                        description: Text("Projects authorized on your Mac appear here after sync.")
                    )
                } else {
                    Section("Open a login shell in a project") {
                        ForEach(state.projects, id: \.id) { project in
                            Button {
                                start(project: project)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                                        Text(project.displayName)
                                            .font(DeckFont.callout.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(project.branch ?? project.canonicalPath)
                                            .font(DeckFont.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if startingProjectID == project.id {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .disabled(startingProjectID != nil)
                        }
                    }
                }
                if let sessionError = state.error(for: .session) {
                    Section {
                        Text(sessionError)
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }
            }
            .navigationTitle("New Shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onStarted(nil) }
                }
            }
        }
    }

    private func start(project: ProjectRecord) {
        startingProjectID = project.id
        Task {
            let sessionID = await state.startTerminal(projectID: project.id)
            if sessionID != nil {
                DeckHaptics.send()
            }
            onStarted(sessionID)
        }
    }
}

// MARK: - New Session sheet (§7.2 flow; system form, token actions)

/// Session start flow: project picker (mirrored projects) + agent picker
/// (mirrored agent state) + prompt, sent as `session.start`.
private struct NewSessionSheet: View {
    @Bindable var state: IOSAppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID: ProjectID?
    @State private var selectedAgentID: AgentIdentifier?
    @State private var prompt = ""
    @State private var model = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    if state.projects.isEmpty {
                        Text("No projects mirrored yet — projects authorized on your Mac appear here after sync.")
                            .font(DeckFont.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $selectedProjectID) {
                            ForEach(state.projects, id: \.id) { project in
                                Text(project.displayName).tag(Optional(project.id))
                            }
                        }
                    }
                }
                Section("Agent") {
                    Picker("Agent", selection: $selectedAgentID) {
                        ForEach(state.agentCards) { card in
                            Text(card.displayName).tag(Optional(card.id))
                        }
                    }
                    if let selectedAgentID,
                       let card = state.agentCards.first(where: { $0.id == selectedAgentID }),
                       !card.isObservedInstalled {
                        Label("This agent has not been observed on your Mac — the start request may be rejected.", systemImage: "exclamationmark.triangle")
                            .font(DeckFont.footnote)
                            .foregroundStyle(DeckColor.warning)
                    }
                }
                Section("Prompt") {
                    TextField("What should the agent do?", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section("Model (optional)") {
                    TextField("Provider model selector", text: $model)
                        .font(DeckFont.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let sessionError = state.error(for: .session) {
                    Section {
                        Text(sessionError)
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let projectID = selectedProjectID,
                              let agentID = selectedAgentID else { return }
                        DeckHaptics.send()
                        Task {
                            await state.startSession(
                                projectID: projectID,
                                agentID: agentID,
                                prompt: prompt,
                                model: model
                            )
                            if state.error(for: .session) == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canStart)
                }
            }
            .onAppear {
                if selectedProjectID == nil {
                    selectedProjectID = state.projects.first?.id
                }
                if selectedAgentID == nil {
                    selectedAgentID = state.agentCards.first(where: { $0.isObservedInstalled })?.id
                        ?? state.agentCards.first?.id
                }
            }
        }
    }

    private var canStart: Bool {
        selectedProjectID != nil
            && selectedAgentID != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
