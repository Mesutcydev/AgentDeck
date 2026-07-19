//
//  SessionView.swift
//  App — AgentDeck
//
//  §29 session screen (DESIGN §7.4): per-agent themed header and terminal
//  chrome, timeline, raw output, and diff mirroring. The terminal wrapper
//  borrows the session agent's product personality (§3) without
//  impersonating it — the AgentDeck header stays visible.
//

import SwiftUI
import Shared

enum SessionSurface: String, CaseIterable, Identifiable {
    case timeline = "Activity"
    case terminal = "Console"
    case rawOutput = "Output"
    case diffs = "Changes"

    var id: String { rawValue }
}

struct SessionView: View {
    @Bindable var state: IOSAppState
    let session: SessionRecord
    @State private var model: TerminalSessionModel
    @State private var surface: SessionSurface = .timeline
    @State private var events: [AgentEvent] = []
    @State private var composerText = ""
    @State private var sendCount = 0
    @FocusState private var composerFocused: Bool

    init(state: IOSAppState, session: SessionRecord, model: TerminalSessionModel) {
        self.state = state
        self.session = session
        _model = State(initialValue: model)
    }

    private var theme: AgentTheme {
        AgentThemes.theme(for: session.agent)
    }

    private var livePendingApproval: ApprovalRequest? {
        state.pendingApproval(for: session.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            agentHeader

            switch surface {
            case .timeline:
                SessionTimelineView(
                    events: events,
                    streamedOutput: model.rawOutputText,
                    isStreaming: !session.state.isTerminal,
                    sessionState: session.state,
                    agentName: agentDisplayName,
                    agentGlyph: theme.glyph,
                    agentTheme: theme,
                    accent: theme.accent,
                    pendingApproval: livePendingApproval,
                    onResolveApproval: { choice, request in
                        resolveApproval(choice, for: request)
                    },
                    onOpenConsole: { surface = .terminal },
                    onOpenChanges: { surface = .diffs }
                )
            case .terminal:
                terminalSurface
            case .rawOutput:
                RawOutputView(text: model.rawOutputText, theme: theme)
            case .diffs:
                diffSurface
            }

            if let sessionError = state.error(for: .session) {
                Text(sessionError)
                    .font(DeckFont.footnote)
                    .foregroundStyle(DeckColor.danger)
                    .padding(.horizontal, DeckSpace.m)
            }

            if let pendingApproval = livePendingApproval, surface != .timeline {
                SessionApprovalDock(request: pendingApproval, theme: theme) { choice in
                    resolveApproval(choice, for: pendingApproval)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if livePendingApproval == nil {
                composer
            }
        }
        .foregroundStyle(theme.workspaceText)
        .background { theme.workspaceBackground.ignoresSafeArea() }
        .tint(theme.accent)
        .sensoryFeedback(.selection, trigger: surface)
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(theme.workspaceBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(theme.usesProviderSkin ? .dark : .light, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    composerFocused = false
                    DeckHaptics.light()
                }
                .fontWeight(.semibold)
            }
        }
        .task(id: state.eventRevision) {
            await reloadTimeline()
        }
        .task(id: surface) {
            if surface == .diffs,
               state.diffContents[session.id] == nil,
               state.diffErrors[session.id] == nil {
                await state.requestDiff(sessionID: session.id)
            }
        }
    }

    private var agentDisplayName: String {
        AgentCatalog.descriptor(for: session.agent)?.displayName ?? session.agent.rawValue
    }

    private var sessionTitle: String {
        guard let projectID = session.projectID else { return agentDisplayName }
        return state.projects.first(where: { $0.id == projectID })?.displayName ?? agentDisplayName
    }

    // MARK: - Agent header (§7.4, 40 pt)

    private var agentHeader: some View {
        HStack(spacing: DeckSpace.s) {
            ProviderMark(theme: theme, size: 28, isLive: !session.state.isTerminal)
            VStack(alignment: .leading, spacing: 2) {
                Text(agentDisplayName)
                    .font(DeckFont.callout.weight(.semibold))
                    .foregroundStyle(theme.workspaceText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(sessionTitle == agentDisplayName ? "REMOTE SESSION" : sessionTitle.uppercased())
                    .font(DeckFont.monoSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(session.state.isTerminal ? Color.secondary : theme.accent)
                    .frame(width: 6, height: 6)
                Text(session.state.compactDisplayName.uppercased())
                    .font(DeckFont.monoSmall.weight(.medium))
                    .foregroundStyle(theme.workspaceText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DeckSpace.m)
        .frame(height: 52)
        .background(theme.workspaceBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.workspaceRule).frame(height: 0.75) }
    }

    // MARK: - Terminal surface (§7.4)

    private var terminalSurface: some View {
        VStack(spacing: 0) {
            // Chrome strip: 36 pt, traffic-light dots tinted to the agent
            // theme, session title, interaction toggle.
            HStack(spacing: DeckSpace.xs) {
                HStack(spacing: DeckSpace.xs) {
                    Circle().fill(theme.accent).frame(width: 10, height: 10)
                    Circle().fill(theme.accent.opacity(0.6)).frame(width: 10, height: 10)
                    Circle().fill(theme.accent.opacity(0.3)).frame(width: 10, height: 10)
                }
                Text(session.id.wireString.prefix(8).lowercased())
                    .font(DeckFont.monoSmall)
                    .foregroundStyle(theme.terminalText.opacity(0.6))
                Spacer()
                Button {
                    UIPasteboard.general.string = model.rawOutputText
                    DeckHaptics.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(DeckFont.footnote.weight(.semibold))
                        .foregroundStyle(theme.terminalText.opacity(0.75))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Copy console output")
                .disabled(model.rawOutputText.isEmpty)
                Button {
                    let next: TerminalInteractionMode =
                        model.interactionMode == .interactive ? .readOnlyRawOutput : .interactive
                    model.setInteractionMode(next)
                } label: {
                    Text(model.interactionMode == .interactive ? "Interactive" : "Read-only")
                        .font(DeckFont.footnote.weight(.medium))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, DeckSpace.s)
            .frame(height: 36)
            .background(theme.terminalBackground)

            TerminalEngineView(model: model, theme: theme)
                .background(theme.terminalBackground)
                .padding(.horizontal, DeckSpace.xs)
                .padding(.bottom, DeckSpace.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous)
                .stroke(theme.terminalText.opacity(0.1), lineWidth: 0.5)
        }
        .padding(.horizontal, DeckSpace.m)
        .padding(.bottom, DeckSpace.xs)
        .task {
            // Reattach on every entry: the companion replays scrollback,
            // then live output continues.
            await state.attachTerminal(sessionID: session.id)
            // Attach can race the first UIKit layout callback. Re-assert the
            // remembered geometry after the host knows this PTY subscriber.
            model.resendCurrentSize()
        }
    }

    // MARK: - Composer (§7.4 floating glass capsule)

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeckSpace.xs) {
                TextField("Message \(agentDisplayName)…", text: $composerText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(DeckFont.body)
                    .foregroundStyle(theme.workspaceText)
                    .colorScheme(theme.usesProviderSkin ? .dark : .light)
                    .focused($composerFocused)
                Button {
                    sendComposerMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.terminalBackground)
                        .frame(width: 38, height: 38)
                        .background(theme.workspaceText)
                        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.38 : 1)
            }
            .padding(.horizontal, DeckSpace.m)
            .padding(.vertical, DeckSpace.xs)
        }
        .background(theme.workspaceSurface)
        .overlay(alignment: .top) { Rectangle().fill(theme.workspaceRule).frame(height: 0.75) }
        .animation(DeckMotion.quick, value: composerFocused)
        .disabled(session.state.isTerminal)
        .opacity(session.state.isTerminal ? 0.5 : 1)
    }

    private func sendComposerMessage() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        sendCount += 1
        DeckHaptics.send()
        Task { await state.sendPrompt(sessionID: session.id, text: text) }
    }

    // MARK: - Diff surface (§29; §7.4 banner)

    /// Live `diff.content` mirrored from the companion.
    @ViewBuilder
    private var diffSurface: some View {
        if let content = state.diffContents[session.id] {
            VStack(spacing: 0) {
                if content.truncated {
                    Label(
                        "Diff exceeded the transport cap — showing the first part only.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(DeckFont.footnote)
                    .foregroundStyle(DeckColor.warning)
                    .padding(DeckSpace.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeckColor.warning.opacity(0.12))
                }
                if let document = try? UnifiedDiffParser.parse(content.unifiedDiff),
                   !document.files.isEmpty {
                    DiffBrowserView(document: document)
                } else if content.unifiedDiff.isEmpty {
                    ContentUnavailableView(
                        "No Changes",
                        systemImage: "checkmark.circle",
                        description: Text("The working tree matches HEAD for this session's project.")
                    )
                } else {
                    // Truncation can cut mid-file so the text no longer
                    // parses — fall back to the raw unified view honestly.
                    ScrollView {
                        Text(content.unifiedDiff)
                            .font(DeckFont.monoSmall)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DeckSpace.m)
                    }
                }
                HStack {
                    Text("\(content.files.count) files · +\(content.totalAdditions) −\(content.totalDeletions)")
                        .font(DeckFont.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        Task { await state.requestDiff(sessionID: session.id) }
                    }
                    .font(DeckFont.footnote)
                }
                .padding(.horizontal, DeckSpace.m)
                .padding(.vertical, DeckSpace.xs)
            }
        } else {
            VStack(spacing: DeckSpace.s) {
                ContentUnavailableView(
                    "No Diff Loaded",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Fetch the working-tree diff for this session from your Mac.")
                )
                Button("Load Diff") {
                    Task { await state.requestDiff(sessionID: session.id) }
                }
                .buttonStyle(.glass)
                if let diffError = state.diffErrors[session.id] {
                    Text(diffError)
                        .font(DeckFont.footnote)
                        .foregroundStyle(DeckColor.danger)
                        .padding(.horizontal, DeckSpace.m)
                }
            }
        }
    }

    /// Live timeline from the mirror-persisted local repository.
    private func reloadTimeline() async {
        events = await state.timelineEvents(sessionID: session.id)
    }

    private func resolveApproval(_ choice: ApprovalChoice, for request: ApprovalRequest) {
        if choice.authorizes {
            DeckHaptics.success()
        } else {
            DeckHaptics.warning()
        }
        Task { await state.resolveApproval(request, choice: choice) }
    }
}

// MARK: - Diff browser (§7.4 colors)

private struct DiffBrowserView: View {
    let document: UnifiedDiffDocument
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedPath: String?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 0) {
                    splitDiffList
                        .frame(maxWidth: 280)
                    Divider()
                    diffDetail
                }
            } else {
                NavigationStack {
                    compactDiffList
                        .navigationTitle("Changed Files")
                }
            }
        }
        .task {
            if selectedPath == nil {
                selectedPath = document.files.first?.changedFile.path
            }
        }
    }

    private var splitDiffList: some View {
        List(selection: $selectedPath) {
            ForEach(document.files) { file in
                VStack(alignment: .leading, spacing: DeckSpace.xxs) {
                    Text(file.changedFile.path)
                        .font(DeckFont.caption.weight(.semibold))
                    Text("\(file.changedFile.status.rawValue) · +\(file.changedFile.additions) −\(file.changedFile.deletions)")
                        .font(DeckFont.footnote)
                        .foregroundStyle(.secondary)
                }
                .tag(file.changedFile.path)
            }
        }
    }

    private var compactDiffList: some View {
        List(document.files) { file in
            NavigationLink(file.changedFile.path) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.header ?? "")")
                                .font(DeckFont.monoSmall)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, DeckSpace.xxs)
                            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                                Text(linePrefix(line.kind) + line.text)
                                    .font(DeckFont.monoSmall)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, DeckSpace.xs)
                                    .padding(.vertical, 2)
                                    .background(backgroundColor(for: line.kind))
                            }
                        }
                    }
                    .padding(DeckSpace.m)
                }
                .navigationTitle(file.changedFile.path)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @ViewBuilder
    private var diffDetail: some View {
        if let selectedFile {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(selectedFile.hunks.enumerated()), id: \.offset) { _, hunk in
                        Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ \(hunk.header ?? "")")
                            .font(DeckFont.monoSmall)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, DeckSpace.xxs)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            Text(linePrefix(line.kind) + line.text)
                                .font(DeckFont.monoSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DeckSpace.xs)
                                .padding(.vertical, 2)
                                .background(backgroundColor(for: line.kind))
                        }
                    }
                }
                .padding(DeckSpace.m)
            }
        } else {
            ContentUnavailableView(
                "Select a File",
                systemImage: "doc.text",
                description: Text("Choose a changed file to inspect its unified diff.")
            )
        }
    }

    private var selectedFile: UnifiedDiffFile? {
        document.files.first(where: { $0.changedFile.path == selectedPath }) ?? document.files.first
    }

    private func linePrefix(_ kind: UnifiedDiffLineKind) -> String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
    }

    private func backgroundColor(for kind: UnifiedDiffLineKind) -> Color {
        switch kind {
        case .context:
            .clear
        case .addition:
            DeckColor.success.opacity(0.16)
        case .deletion:
            DeckColor.danger.opacity(0.16)
        }
    }
}
