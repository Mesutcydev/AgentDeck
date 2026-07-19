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
    @State private var isPresentingNewShell = false
    @State private var launchingAgentID: AgentIdentifier?
    @State private var path: [SessionID] = []
    @AppStorage("home.agentOrder") private var persistedAgentOrder = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isConnected: Bool {
        if let activeHostID = state.activeHostID {
            return state.connectedDeviceIDs.contains(activeHostID)
        }
        return !state.connectedDeviceIDs.isEmpty
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HomeCommandHero(
                        greeting: greeting,
                        macName: state.activeHost?.displayName ?? state.pairedDevices.first?.displayName ?? "Pair a Mac",
                        connectionStatus: state.remoteConnectionStatus,
                        isConnected: isConnected,
                        installedAgents: state.agentCards.filter(\.isObservedInstalled).count,
                        totalSessions: state.sessions.count,
                        runningSessions: state.activeSessions.count,
                        projectName: state.projects.first?.displayName ?? "No project",
                        pendingApprovals: state.pendingApprovalRecords.count
                    )
                    HostSwitcherButton(state: state)
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
            .safeAreaPadding(.top, DeckSpace.s)
            .background { DeckCanvas() }
            .tint(DeckColor.accent)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .refreshable { await refreshAll() }
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
                            state.projects.isEmpty || launchingAgentID != nil
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
            HStack(spacing: DeckSpace.s) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(DeckColor.accent)
                Text("Tap a provider to start it instantly")
                    .font(DeckFont.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                isPresentingNewShell = true
            } label: {
                Label("New Shell", systemImage: "terminal")
                    .font(DeckFont.callout.weight(.semibold))
                    .padding(.horizontal, DeckSpace.m)
                    .frame(height: 56)
            }
            .buttonStyle(DeckActionButtonStyle())
            .disabled(!isConnected)
        }
    }

    private func refreshAll() async {
        await state.refreshDevices()
        await state.refreshSessions()
        await state.refreshProjects()
        await state.refreshApprovalState()
    }

    /// A provider row is the launch button: it starts that provider's native
    /// structured adapter without an intermediate composer. The first prompt
    /// is entered in the session GUI; New Shell remains the explicit PTY path.
    private func launch(_ card: IOSAppState.AgentCard) {
        guard card.isObservedInstalled,
              launchingAgentID == nil,
              let project = state.projects.first else { return }
        launchingAgentID = card.id
        DeckHaptics.send()
        Task {
            let sessionID = await state.startSession(
                projectID: project.id,
                agentID: card.id,
                prompt: "",
                model: nil
            )
            launchingAgentID = nil
            if let sessionID { path = [sessionID] }
        }
    }
}

private struct DuplicateProviderSheet: View {
    let providerID: AgentIdentifier
    let providerName: String
    let resume: () -> Void
    let startAnother: () -> Void
    let cancel: () -> Void

    private var theme: AgentTheme { AgentThemes.theme(for: providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSpace.l) {
            LaunchSheetHeader(
                index: "LIVE / 01",
                title: "\(providerName) is running",
                detail: "Continue the live conversation, or create a deliberate parallel session.",
                systemImage: theme.glyph,
                accent: theme.accent,
                textColor: theme.workspaceText
            )
            HStack(spacing: DeckSpace.m) {
                ProviderMark(theme: theme, size: 44, isLive: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(providerName).font(DeckFont.headline)
                    Text("ACTIVE SESSION").font(DeckFont.monoSmall).foregroundStyle(theme.accent)
                }
            }
            Button(action: resume) {
                Label("Resume current session", systemImage: "arrow.up.right")
                    .font(DeckFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.terminalBackground)
            .background(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))

            Button(action: startAnother) {
                Label("Start another session", systemImage: "plus")
                    .font(DeckFont.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.workspaceText)
            .background(theme.workspaceSurface)
            .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(theme.workspaceRule) }
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))

            Button("Cancel", action: cancel)
                .font(DeckFont.footnote.weight(.semibold))
                .foregroundStyle(theme.workspaceText.opacity(0.58))
                .frame(maxWidth: .infinity)
        }
        .padding(DeckSpace.l)
        .foregroundStyle(theme.workspaceText)
        .background(theme.workspaceBackground.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

private struct HomeCommandHero: View {
    let greeting: String
    let macName: String
    let connectionStatus: String
    let isConnected: Bool
    let installedAgents: Int
    let totalSessions: Int
    let runningSessions: Int
    let projectName: String
    let pendingApprovals: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSpace.m) {
            HStack(alignment: .center, spacing: DeckSpace.s) {
                DeckMark(size: 28, color: DeckColor.ink, showsSignal: false)
                HStack(spacing: 0) {
                    Text("AGENT").foregroundStyle(DeckColor.ink)
                    Text("/DECK").foregroundStyle(DeckColor.accent)
                }
                .font(.system(size: 29, weight: .black))
                .tracking(-1.4)
                Spacer()
                LiveStatusDot(isLive: isConnected)
            }

            VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                Text(greeting)
                    .font(DeckFont.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Control your agents.")
                    .font(DeckFont.display)
                    .tracking(-1.2)
            }

            HStack(spacing: DeckSpace.s) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isConnected ? DeckColor.activity : .secondary)
                    .frame(width: 40, height: 40)
                    .background(DeckColor.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONNECTED TO")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(macName)
                        .font(DeckFont.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(connectionStatus)
                        .font(DeckFont.footnote)
                        .foregroundStyle(isConnected ? DeckColor.activity : .secondary)
                        .lineLimit(1)
                }
                Spacer()
                if pendingApprovals > 0 {
                    Label("\(pendingApprovals)", systemImage: "checkmark.shield.fill")
                        .font(DeckFont.monoSmall.weight(.bold))
                        .foregroundStyle(DeckColor.warning)
                }
            }

            HStack(spacing: 0) {
                HomeHeroMetric(value: installedAgents, label: "Agents")
                HomeHeroMetric(value: totalSessions, label: "Sessions")
                HomeHeroMetric(value: runningSessions, label: "Running", tint: DeckColor.activity)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CURRENT PROJECT")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(projectName)
                        .font(DeckFont.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, DeckSpace.xs)
            .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
        }
        .padding(DeckSpace.m)
        .foregroundStyle(DeckColor.ink)
        .background {
            ZStack {
                DeckColor.surface
                DeckTerminalGrid().opacity(0.32)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous)
                .stroke(isConnected ? DeckColor.activity.opacity(0.38) : DeckColor.rule, lineWidth: 1)
        }
        .shadow(color: isConnected ? DeckColor.activity.opacity(0.1) : .clear, radius: 20, y: 8)
    }
}

private struct HomeHeroMetric: View {
    let value: Int
    let label: String
    var tint: Color = DeckColor.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
                .foregroundStyle(tint)
            Text(label)
                .font(DeckFont.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LiveStatusDot: View {
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulses = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? DeckColor.activity : Color.secondary)
                .frame(width: 8, height: 8)
                .scaleEffect(pulses ? 1.15 : 0.85)
            Text(isLive ? "ONLINE" : "OFFLINE")
        }
        .font(.caption2.monospaced().weight(.bold))
        .foregroundStyle(isLive ? DeckColor.activity : .secondary)
        .task {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulses = true
            }
        }
    }
}

// MARK: - Active host switcher

private struct HostSwitcherButton: View {
    @Bindable var state: IOSAppState
    @State private var isPresentingHosts = false

    var body: some View {
        Button {
            isPresentingHosts = true
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
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingHosts) {
            HostPickerSheet(state: state)
        }
        .accessibilityLabel("Active Mac, \(state.activeHost?.displayName ?? "none selected")")
        .accessibilityHint("Switch the Mac used for new agent sessions")
    }

    private var activeIsConnected: Bool {
        guard let id = state.activeHostID else { return false }
        return state.connectedDeviceIDs.contains(id)
    }
}

private struct HostPickerSheet: View {
    @Bindable var state: IOSAppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.l) {
                    LaunchSheetHeader(
                        index: "MAC / 01",
                        title: "Choose your Mac",
                        detail: "Agent launches, projects, and sessions follow this endpoint.",
                        systemImage: "desktopcomputer"
                    )
                    ForEach(state.pairedDevices.filter { !$0.revoked }, id: \.id) { device in
                        Button {
                            Task {
                                await state.selectHost(device.id)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: DeckSpace.m) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(device.id == state.activeHostID ? DeckColor.accent : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.displayName).font(DeckFont.headline)
                                    Text(state.connectedDeviceIDs.contains(device.id) ? "ONLINE" : "OFFLINE")
                                        .font(DeckFont.monoSmall.weight(.semibold))
                                        .foregroundStyle(state.connectedDeviceIDs.contains(device.id) ? DeckColor.activity : .secondary)
                                }
                                Spacer()
                                if device.id == state.activeHostID {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DeckColor.accent)
                                } else {
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                }
                            }
                            .padding(DeckSpace.m)
                            .background(DeckColor.surface)
                            .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(DeckColor.rule) }
                            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DeckSpace.l)
            }
            .background { DeckCanvas() }
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
            ScrollView {
                shellContent
                    .padding(DeckSpace.l)
            }
            .background { DeckCanvas() }
            .navigationTitle("New shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onStarted(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var shellContent: some View {
        VStack(alignment: .leading, spacing: DeckSpace.l) {
                    LaunchSheetHeader(
                        index: "SHELL / 01",
                        title: "Open a shell",
                        detail: "Choose an authorized project. AgentDeck will open one login shell on your selected Mac.",
                        systemImage: "terminal"
                    )

                    if state.projects.isEmpty {
                        ContentUnavailableView(
                            "No projects synced",
                            systemImage: "folder.badge.questionmark",
                            description: Text("Authorize a project in Companion, then pull to refresh Home.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        Text("PROJECT")
                            .font(DeckFont.monoSmall.weight(.semibold))
                            .foregroundStyle(DeckColor.accent)
                        ForEach(state.projects, id: \.id) { project in
                            Button {
                                start(project: project)
                            } label: {
                                HStack(spacing: DeckSpace.m) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(DeckColor.accent)
                                        .frame(width: 42, height: 42)
                                        .background(DeckColor.accent.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card))
                                    VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                                        Text(project.displayName)
                                            .font(DeckFont.headline)
                                        Text(project.branch ?? project.canonicalPath)
                                            .font(DeckFont.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    if startingProjectID == project.id {
                                        ProgressView()
                                            .tint(DeckColor.accent)
                                    } else {
                                        Image(systemName: "arrow.right")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(DeckColor.accent)
                                    }
                                }
                                .padding(DeckSpace.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DeckColor.surface)
                                .overlay {
                                    RoundedRectangle(cornerRadius: DeckRadius.card)
                                        .stroke(DeckColor.rule, lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(startingProjectID != nil)
                        }
                    }

                    if let sessionError = state.error(for: .session) {
                        LaunchErrorCard(message: sessionError)
                    }
        }
    }

    private func start(project: ProjectRecord) {
        startingProjectID = project.id
        Task {
            let sessionID = await state.startTerminal(projectID: project.id)
            if let sessionID {
                DeckHaptics.send()
                onStarted(sessionID)
            } else {
                startingProjectID = nil
            }
        }
    }
}

// MARK: - New Session sheet (§7.2 structured provider flow)

/// Session start flow: project picker (mirrored projects) + agent picker
/// (mirrored agent state) + prompt, sent as `session.start`.
private struct NewSessionSheet: View {
    @Bindable var state: IOSAppState
    let initialAgentID: AgentIdentifier?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID: ProjectID?
    @State private var selectedAgentID: AgentIdentifier?
    @State private var prompt = ""
    @State private var model = ""
    @State private var isStarting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                sessionContent
                    .padding(DeckSpace.l)
            }
            .background { sheetBackground.ignoresSafeArea() }
            .foregroundStyle(sheetText)
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if selectedProjectID == nil {
                    selectedProjectID = state.projects.first?.id
                }
                if selectedAgentID == nil {
                    selectedAgentID = initialAgentID
                        ?? availableAgents.first?.id
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var sessionContent: some View {
        VStack(alignment: .leading, spacing: DeckSpace.l) {
            LaunchSheetHeader(
                index: "AGENT / 01",
                title: "Start an agent",
                detail: "Describe the outcome. AgentDeck will stream the provider as native messages, actions, files, and approvals.",
                systemImage: selectedTheme.glyph,
                accent: selectedTheme.accent,
                textColor: sheetText
            )
            projectSelector
            providerSelector
            taskEditor
            modelEditor

            if let sessionError = state.error(for: .session) {
                LaunchErrorCard(message: sessionError)
            }

            Button(action: start) {
                HStack {
                    if isStarting { ProgressView().tint(selectedTheme.terminalBackground) }
                    Label(isStarting ? "Starting…" : "Start structured session", systemImage: "arrow.up.right")
                    Spacer()
                    Text("GUI").font(.caption2.monospaced().weight(.bold))
                }
                .font(DeckFont.callout.weight(.semibold))
                .padding(.horizontal, DeckSpace.m)
                .frame(height: 58)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selectedTheme.terminalBackground)
            .background(canStart ? selectedTheme.accent : selectedTheme.accent.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
            .disabled(!canStart || isStarting)
        }
    }

    private var availableAgents: [IOSAppState.AgentCard] {
        state.agentCards.filter(\.isObservedInstalled)
    }

    private var selectedTheme: AgentTheme { AgentThemes.theme(for: selectedAgentID) }
    private var sheetBackground: Color { selectedTheme.workspaceBackground }
    private var sheetSurface: Color { selectedTheme.workspaceSurface }
    private var sheetRule: Color { selectedTheme.workspaceRule }
    private var sheetText: Color { selectedTheme.workspaceText }

    private var projectSelector: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            sectionHeading("PROJECT")
            ForEach(state.projects, id: \.id) { project in
                Button {
                    selectedProjectID = project.id
                    DeckHaptics.light()
                } label: {
                    HStack(spacing: DeckSpace.s) {
                        Image(systemName: "folder.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.displayName).font(DeckFont.callout.weight(.semibold))
                            Text(project.branch ?? project.canonicalPath)
                                .font(DeckFont.footnote)
                                .opacity(0.55)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: selectedProjectID == project.id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedProjectID == project.id ? selectedTheme.accent : sheetText.opacity(0.28))
                    }
                    .foregroundStyle(sheetText)
                    .padding(DeckSpace.m)
                    .background(sheetSurface)
                    .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(sheetRule) }
                    .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isStarting)
            }
        }
    }

    private var providerSelector: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            HStack {
                sectionHeading("PROVIDER")
                Spacer()
                Text(selectedTheme.personality.uppercased())
                    .font(DeckFont.monoSmall.weight(.semibold))
                    .foregroundStyle(selectedTheme.accent)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DeckSpace.s) {
                ForEach(availableAgents) { card in
                    ProviderChoiceCard(
                        card: card,
                        isSelected: selectedAgentID == card.id,
                        foreground: sheetText,
                        surface: sheetSurface,
                        rule: sheetRule
                    ) {
                        withAnimation(DeckMotion.quick) { selectedAgentID = card.id }
                        DeckHaptics.light()
                    }
                    .disabled(isStarting)
                }
            }
        }
    }

    private var taskEditor: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            sectionHeading("TASK")
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should the agent accomplish?")
                        .font(DeckFont.body)
                        .foregroundStyle(sheetText.opacity(0.38))
                        .padding(.horizontal, 17)
                        .padding(.vertical, 16)
                }
                TextEditor(text: $prompt)
                    .font(DeckFont.body)
                    .scrollContentBackground(.hidden)
                    .padding(DeckSpace.s)
                    .frame(minHeight: 132)
                    .disabled(isStarting)
                    .foregroundStyle(sheetText)
                    .colorScheme(selectedTheme.usesProviderSkin ? .dark : .light)
            }
            .background(sheetSurface)
            .overlay(alignment: .leading) { Rectangle().fill(selectedTheme.accent).frame(width: 3) }
        }
    }

    private var modelEditor: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            Text("MODEL · OPTIONAL")
                .font(DeckFont.monoSmall.weight(.semibold))
                .foregroundStyle(sheetText.opacity(0.55))
            TextField("Use provider default", text: $model)
                .font(DeckFont.mono)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, DeckSpace.m)
                .frame(height: 52)
                .foregroundStyle(sheetText)
                .colorScheme(selectedTheme.usesProviderSkin ? .dark : .light)
                .background(sheetSurface)
                .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(sheetRule) }
                .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                .disabled(isStarting)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(DeckFont.monoSmall.weight(.semibold))
            .foregroundStyle(selectedTheme.accent)
    }

    private var canStart: Bool {
        selectedProjectID != nil
            && selectedAgentID != nil
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() {
        guard let projectID = selectedProjectID, let agentID = selectedAgentID else { return }
        isStarting = true
        DeckHaptics.send()
        Task {
            await state.startSession(
                projectID: projectID,
                agentID: agentID,
                prompt: prompt,
                model: model
            )
            isStarting = false
            if state.error(for: .session) == nil { dismiss() }
        }
    }
}

private struct ProviderChoiceCard: View {
    let card: IOSAppState.AgentCard
    let isSelected: Bool
    let foreground: Color
    let surface: Color
    let rule: Color
    let select: () -> Void

    private var theme: AgentTheme { AgentThemes.theme(for: card.id) }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: DeckSpace.s) {
                HStack {
                    ProviderMark(theme: theme, size: 30)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? theme.accent : foreground.opacity(0.28))
                }
                Text(card.displayName)
                    .font(DeckFont.callout.weight(.semibold))
                    .lineLimit(1)
                Text(theme.personality.uppercased())
                    .font(DeckFont.monoSmall)
                    .opacity(0.5)
            }
            .foregroundStyle(foreground)
            .padding(DeckSpace.m)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .background(isSelected ? theme.accent.opacity(0.16) : surface)
            .overlay {
                RoundedRectangle(cornerRadius: DeckRadius.card)
                    .stroke(isSelected ? theme.accent : rule, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct LaunchSheetHeader: View {
    let index: LocalizedStringKey
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    var accent: Color = DeckColor.accent
    var textColor: Color = DeckColor.ink

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            HStack {
                Text(index)
                    .font(DeckFont.monoSmall.weight(.semibold))
                    .foregroundStyle(accent)
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(title)
                .font(DeckFont.display)
                .tracking(-1)
                .foregroundStyle(textColor)
            Text(detail)
                .font(DeckFont.callout)
                .foregroundStyle(textColor.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DeckSpace.m)
        .overlay(alignment: .bottom) { Rectangle().fill(textColor.opacity(0.16)).frame(height: 1) }
    }
}

private struct LaunchPickerRow: View {
    let label: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: DeckSpace.m) {
            Image(systemName: systemImage)
                .foregroundStyle(DeckColor.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DeckFont.footnote)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(DeckFont.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DeckColor.accent)
        }
        .padding(.horizontal, DeckSpace.m)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }
}

private struct LaunchErrorCard: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(DeckFont.footnote)
            .foregroundStyle(DeckColor.danger)
            .padding(DeckSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeckColor.danger.opacity(0.08))
            .overlay(alignment: .leading) { Rectangle().fill(DeckColor.danger).frame(width: 3) }
    }
}
