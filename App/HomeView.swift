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
    @State private var launchingAgentID: AgentIdentifier?
    @State private var duplicateProviderID: AgentIdentifier?
    @State private var path: [SessionID] = []
    @AppStorage("home.agentOrder") private var persistedAgentOrder = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isConnected: Bool {
        state.remoteConnectionStatus.hasPrefix("Connected")
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    connectedMacHero
                    quickActions
                    agentGrid
                    activeSessions
                    if let sessionError = state.error(for: .session) {
                        Label(sessionError, systemImage: "exclamationmark.triangle.fill")
                            .font(DeckFont.caption)
                            .foregroundStyle(DeckColor.danger)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
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
            .confirmationDialog(
                duplicateProviderName.map { "\($0) is already running" } ?? "Agent already running",
                isPresented: Binding(
                    get: { duplicateProviderID != nil },
                    set: { if !$0 { duplicateProviderID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Resume Current Session") { resumeDuplicateProvider() }
                Button("Start Another Session") { startDuplicateProvider() }
                Button("Cancel", role: .cancel) { duplicateProviderID = nil }
            } message: {
                Text("Continue the live conversation or deliberately create a separate one.")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: DeckSpace.s) {
                DeckMark(size: 28, color: DeckColor.ink, showsSignal: false)
                HStack(spacing: 0) {
                    Text("AGENT").foregroundStyle(DeckColor.ink)
                    Text("/DECK").foregroundStyle(DeckColor.accent)
                }
                .font(.system(size: 29, weight: .black, design: .default))
                .tracking(-1.4)
            }
            HostSwitcherButton(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.vertical, 6)
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

    private var connectedMacHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("CONNECTED MAC", systemImage: "desktopcomputer")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).tracking(0.8)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(isConnected ? DeckColor.success : Color.secondary).frame(width: 8, height: 8)
                    Text(isConnected ? "LIVE" : "OFFLINE")
                }.font(DeckFont.monoSmall.weight(.bold)).foregroundStyle(isConnected ? DeckColor.success : .secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "macbook").font(.system(size: 27, weight: .medium)).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.pairedDevices.first?.displayName ?? "Pair a Mac")
                        .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text(state.remoteConnectionStatus).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                heroMetric("SESSIONS", "\(state.activeSessions.count)")
                heroMetric("AGENTS", "\(state.agentCards.filter(\.isObservedInstalled).count)")
                heroMetric("PROJECT", state.projects.first?.displayName ?? "—")
            }
        }
        .foregroundStyle(DeckColor.ink).padding(14).frame(minHeight: 136)
        .deckSurface(accent: isConnected ? DeckColor.success : nil, radius: 16)
    }

    private func heroMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionStatus: some View {
        HStack(spacing: DeckSpace.xs) {
            Circle()
                .fill(isConnected ? DeckColor.success : Color(.tertiaryLabel))
                .frame(width: 8, height: 8)
            DeckMarqueeText(text: state.remoteConnectionStatus)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
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
        let count = horizontalSizeClass == .regular ? 2 : 1
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
                    ForEach(orderedAgentCards) { card in
                        Button {
                            launch(card)
                        } label: {
                            AgentCardCell(
                                card: card,
                                isLaunching: launchingAgentID == card.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !isConnected || !card.isObservedInstalled ||
                            launchingAgentID != nil || state.projects.isEmpty
                        )
                        .draggable(card.id.rawValue)
                        .dropDestination(for: String.self) { items, _ in
                            guard let draggedID = items.first else { return false }
                            reorderAgent(draggedID, before: card.id.rawValue)
                            return true
                        }
                        .transition(DeckMotion.appearance(reduceMotion: reduceMotion))
                    }
                }
                .animation(DeckMotion.standard, value: orderedAgentCards.map(\.id))
            }
        }
    }

    private var orderedAgentCards: [IOSAppState.AgentCard] {
        let preferred = persistedAgentOrder.split(separator: "|").map(String.init)
        let ranks = Dictionary(uniqueKeysWithValues: preferred.enumerated().map { ($0.element, $0.offset) })
        return state.agentCards.sorted { lhs, rhs in
            let left = ranks[lhs.id.rawValue] ?? Int.max
            let right = ranks[rhs.id.rawValue] ?? Int.max
            return left == right ? lhs.displayName < rhs.displayName : left < right
        }
    }

    private func reorderAgent(_ draggedID: String, before targetID: String) {
        guard draggedID != targetID else { return }
        var ids = orderedAgentCards.map { $0.id.rawValue }
        guard let source = ids.firstIndex(of: draggedID),
              let target = ids.firstIndex(of: targetID) else { return }
        let moved = ids.remove(at: source)
        ids.insert(moved, at: source < target ? target - 1 : target)
        persistedAgentOrder = ids.joined(separator: "|")
        DeckHaptics.light()
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                DeckHaptics.warning()
                                Task { await state.deleteSession(session) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                DeckHaptics.warning()
                                Task { await state.interruptSession(sessionID: session.id) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button {
                                Task { await state.interruptSession(sessionID: session.id) }
                            } label: {
                                Label("Stop Session", systemImage: "stop.fill")
                            }
                            Button(role: .destructive) {
                                Task { await state.deleteSession(session) }
                            } label: {
                                Label("Delete Session", systemImage: "trash")
                            }
                        }
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
                    .frame(height: 56)
            }
            .buttonStyle(DeckActionButtonStyle(primary: true))
            .disabled(!isConnected)

            Button {
                isPresentingNewShell = true
            } label: {
                Label("New Shell", systemImage: "terminal")
                    .font(DeckFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
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

    /// Provider cards are launch controls, not decoration. A tap starts the
    /// discovered CLI in the first authorized project and opens its live PTY.
    private func launch(_ card: IOSAppState.AgentCard) {
        guard card.isObservedInstalled, let project = state.projects.first else { return }
        if state.activeSessions.contains(where: { $0.agent == card.id }) {
            duplicateProviderID = card.id
            DeckHaptics.light()
            return
        }
        launchNew(card, project: project)
    }

    private var duplicateProviderName: String? {
        guard let id = duplicateProviderID else { return nil }
        return state.agentCards.first(where: { $0.id == id })?.displayName
    }

    private func resumeDuplicateProvider() {
        guard let id = duplicateProviderID,
              let session = state.activeSessions.first(where: { $0.agent == id }) else {
            duplicateProviderID = nil
            return
        }
        duplicateProviderID = nil
        path = [session.id]
    }

    private func startDuplicateProvider() {
        guard let id = duplicateProviderID,
              let card = state.agentCards.first(where: { $0.id == id }),
              let project = state.projects.first else {
            duplicateProviderID = nil
            return
        }
        duplicateProviderID = nil
        launchNew(card, project: project)
    }

    private func launchNew(_ card: IOSAppState.AgentCard, project: ProjectRecord) {
        launchingAgentID = card.id
        DeckHaptics.send()
        Task {
            let sessionID = await state.startTerminal(projectID: project.id, agentID: card.id)
            launchingAgentID = nil
            if let sessionID { path = [sessionID] }
        }
    }
}

// MARK: - Active host switcher

private struct HostSwitcherButton: View {
    @Bindable var state: IOSAppState

    var body: some View {
        Menu {
            if state.pairedDevices.isEmpty {
                Text("No paired Macs")
            } else {
                ForEach(state.pairedDevices.filter { !$0.revoked }, id: \.id) { device in
                    Button {
                        Task { await state.selectHost(device.id) }
                    } label: {
                        Label {
                            Text(device.displayName)
                        } icon: {
                            Image(systemName: device.id == state.activeHostID ? "checkmark.circle.fill" : "desktopcomputer")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DeckColor.ink)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DeckColor.canvas)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.activeHost?.displayName ?? "SELECT MAC")
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(DeckColor.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(activeIsConnected ? DeckColor.success : Color(.tertiaryLabel))
                            .frame(width: 5, height: 5)
                        Text(activeIsConnected ? "LIVE" : "OFFLINE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(DeckColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous)
                    .stroke(DeckColor.rule, lineWidth: 0.75)
            }
        }
        .accessibilityLabel("Active Mac, \(state.activeHost?.displayName ?? "none selected")")
        .accessibilityHint("Switch the Mac used for new agent sessions")
    }

    private var activeIsConnected: Bool {
        guard let id = state.activeHostID else { return false }
        return state.connectedDeviceIDs.contains(id)
    }
}

// MARK: - Agent card cell (§7.2: 96 pt, radius 14, padding 12)

private struct AgentCardCell: View {
    let card: IOSAppState.AgentCard
    let isLaunching: Bool

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
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if isLaunching {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else {
                HStack(spacing: DeckSpace.xs) {
                    Text(statusLine)
                        .font(DeckFont.monoSmall)
                        .foregroundStyle(card.activeSessionCount > 0 ? theme.accent : Color.secondary)
                        .lineLimit(1)
                    if card.isObservedInstalled {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.displayName), \(statusLine)")
        .accessibilityHint(card.isObservedInstalled ? "Starts this provider in your default project" : "Provider is not installed on the paired Mac")
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
