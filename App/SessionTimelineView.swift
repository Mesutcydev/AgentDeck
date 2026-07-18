//
//  SessionTimelineView.swift
//  App — AgentDeck
//
//  §29 Phase 6 native timeline consuming shared AgentEvent models only.
//  Rendering is unknown-tolerant: event kinds added to the contract later
//  (plan, fileSearch, build, test, warning, transport, …) fall through to
//  a labeled raw display instead of crashing or vanishing.
//

import SwiftUI
import Shared

struct SessionTimelineView: View {
    let events: [AgentEvent]
    let streamedOutput: String
    let isStreaming: Bool
    let agentName: String
    let agentGlyph: String
    let agentTheme: AgentTheme
    /// Agent accent used sparingly: sequence markers and the uncertain
    /// chip border (DESIGN §3 — accent in exactly three places rule).
    var accent: Color = DeckColor.accent
    let pendingApproval: ApprovalRequest?
    let onResolveApproval: (ApprovalChoice, ApprovalRequest) -> Void
    let onOpenConsole: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isNearBottom = true
    @State private var isFollowingLive = true

    var body: some View {
        if events.isEmpty && streamedOutput.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "text.bubble",
                description: Text("Messages, commands, edits, and approvals will appear here as the agent works.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DeckSpace.l) {
                            ForEach(displayedEvents) { event in
                                TimelineEventRow(
                                    event: event,
                                    agentName: agentName,
                                    agentGlyph: agentGlyph,
                                    agentTheme: agentTheme,
                                    accent: accent
                                )
                            }

                            if !streamedOutput.isEmpty {
                                LiveAgentResponseView(
                                    text: streamedOutput,
                                    isStreaming: isStreaming,
                                    agentName: agentName,
                                    agentGlyph: agentGlyph,
                                    agentTheme: agentTheme,
                                    accent: accent,
                                    onOpenConsole: onOpenConsole
                                )
                                .id("live-stream")
                            }

                            if let pendingApproval {
                                ChatApprovalCard(
                                    request: pendingApproval,
                                    onResolve: { choice in
                                        onResolveApproval(choice, pendingApproval)
                                    }
                                )
                                .id("pending-approval")
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("timeline-bottom")
                        }
                        .padding(.horizontal, DeckSpace.m)
                        .padding(.top, DeckSpace.l)
                        .padding(.bottom, DeckSpace.xl)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let distanceFromBottom = geometry.contentSize.height
                            - geometry.containerSize.height
                            - geometry.contentOffset.y
                        return distanceFromBottom < 240
                    } action: { _, nearBottom in
                        isNearBottom = nearBottom
                        if nearBottom {
                            isFollowingLive = true
                        }
                    }
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .interacting {
                            isFollowingLive = false
                        }
                    }

                    if !isFollowingLive {
                        Button {
                            isFollowingLive = true
                            isNearBottom = true
                            scrollToLive(using: proxy)
                        } label: {
                            HStack(spacing: DeckSpace.xs) {
                                Circle()
                                    .fill(isStreaming ? accent : agentTheme.workspaceText.opacity(0.4))
                                    .frame(width: 6, height: 6)
                                Text("JUMP TO LIVE")
                                Image(systemName: "arrow.down")
                            }
                            .font(.caption2.monospaced().weight(.semibold))
                            .padding(.horizontal, DeckSpace.s)
                            .frame(height: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(agentTheme.workspaceBackground)
                        .background(agentTheme.workspaceText)
                        .overlay { Rectangle().stroke(agentTheme.workspaceRule, lineWidth: 1) }
                        .padding(DeckSpace.m)
                    }
                }
                .onChange(of: streamedOutput.count) {
                    guard isFollowingLive else { return }
                    scrollToLive(using: proxy)
                }
                .onChange(of: events.count) {
                    guard isFollowingLive else { return }
                    scrollToLive(using: proxy)
                }
            }
        }
    }

    private var displayedEvents: [AgentEvent] {
        return events.filter { event in
            if case .approvalRequested = event.payload { return false }
            return true
        }
    }

    private func scrollToLive(using proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                proxy.scrollTo("timeline-bottom", anchor: .bottom)
            }
        }
    }
}

private struct ChatApprovalCard: View {
    let request: ApprovalRequest
    let onResolve: (ApprovalChoice) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DeckSpace.xs) {
            ZStack {
                DeckMark(size: 30, color: DeckColor.warning)
            }
            .frame(width: 32, height: 32)

            SessionApprovalDock(request: request, onResolve: onResolve)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TimelineEventRow: View {
    let event: AgentEvent
    let agentName: String
    let agentGlyph: String
    let agentTheme: AgentTheme
    let accent: Color

    var body: some View {
        switch event.payload {
        case .messageText(let message):
            ChatMessageRow(
                message: message,
                date: eventDate,
                agentName: agentName,
                agentGlyph: agentGlyph,
                agentTheme: agentTheme,
                accent: accent
            )
        default:
            eventCard
        }
    }

    private var eventCard: some View {
        HStack(alignment: .top, spacing: DeckSpace.s) {
            Image(systemName: style.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: DeckSpace.xs) {
                HStack(spacing: DeckSpace.xs) {
                    Text(style.title)
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .textCase(.uppercase)
                    if event.confidence.requiresUncertaintyIndicator {
                        Text("Uncertain")
                            .font(.caption2)
                            .foregroundStyle(DeckColor.warning)
                    }
                    Spacer()
                    Text(eventDate, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(agentTheme.workspaceText.opacity(0.38))
                }
                Text(summary)
                    .font(bodyFont)
                    .foregroundStyle(agentTheme.workspaceText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DeckSpace.xs)
        .overlay(alignment: .bottom) { Rectangle().fill(agentTheme.workspaceRule).frame(height: 0.75) }
        .accessibilityElement(children: .combine)
    }

    private var eventDate: Date {
        Date(timeIntervalSince1970: Double(event.timestamp) / 1_000)
    }

    private var style: EventVisualStyle {
        switch event.payload {
        case .messageText:
            EventVisualStyle(title: "Agent message", glyph: "bubble.left.fill", tint: accent)
        case .stateChanged:
            EventVisualStyle(title: "Status", glyph: "waveform.path.ecg", tint: accent)
        case .toolCallStarted:
            EventVisualStyle(title: "Using a tool", glyph: "wrench.and.screwdriver.fill", tint: DeckColor.info)
        case .toolCallFinished(let result):
            EventVisualStyle(
                title: result.succeeded ? "Tool finished" : "Tool failed",
                glyph: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill",
                tint: result.succeeded ? DeckColor.success : DeckColor.danger
            )
        case .commandStarted:
            EventVisualStyle(title: "Running command", glyph: "terminal.fill", tint: accent)
        case .commandFinished(let result):
            EventVisualStyle(
                title: result.exitCode == 0 ? "Command finished" : "Command stopped",
                glyph: result.exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                tint: result.exitCode == 0 ? DeckColor.success : DeckColor.warning
            )
        case .fileOperation:
            EventVisualStyle(title: "File changed", glyph: "doc.badge.gearshape", tint: DeckColor.info)
        case .diffAvailable:
            EventVisualStyle(title: "Changes ready", glyph: "plusminus", tint: DeckColor.info)
        case .approvalRequested:
            EventVisualStyle(title: "Decision needed", glyph: "checkmark.shield.fill", tint: DeckColor.warning)
        case .approvalResolved(let resolution):
            EventVisualStyle(
                title: "Decision recorded",
                glyph: resolution.decision.choice.authorizes ? "checkmark.shield.fill" : "xmark.shield.fill",
                tint: resolution.decision.choice.authorizes ? DeckColor.success : DeckColor.danger
            )
        case .waitingForUser:
            EventVisualStyle(title: "Waiting for you", glyph: "person.crop.circle.badge.questionmark", tint: DeckColor.warning)
        case .plan:
            EventVisualStyle(title: "Plan", glyph: "list.bullet.clipboard.fill", tint: accent)
        case .fileSearch:
            EventVisualStyle(title: "Searching files", glyph: "doc.text.magnifyingglass", tint: DeckColor.info)
        case .build(let report):
            EventVisualStyle(
                title: report.succeeded ? "Build passed" : "Build failed",
                glyph: "hammer.fill",
                tint: report.succeeded ? DeckColor.success : DeckColor.danger
            )
        case .test(let report):
            EventVisualStyle(
                title: report.succeeded ? "Tests passed" : "Tests failed",
                glyph: "checkmark.seal.fill",
                tint: report.succeeded ? DeckColor.success : DeckColor.danger
            )
        case .warning:
            EventVisualStyle(title: "Warning", glyph: "exclamationmark.triangle.fill", tint: DeckColor.warning)
        case .completed:
            EventVisualStyle(title: "Completed", glyph: "checkmark.circle.fill", tint: DeckColor.success)
        case .failed:
            EventVisualStyle(title: "Failed", glyph: "xmark.octagon.fill", tint: DeckColor.danger)
        case .rawOutput:
            EventVisualStyle(title: "Raw output", glyph: "text.alignleft", tint: agentTheme.workspaceText.opacity(0.45))
        case .transport:
            EventVisualStyle(title: "Connection", glyph: "antenna.radiowaves.left.and.right", tint: agentTheme.workspaceText.opacity(0.45))
        @unknown default:
            EventVisualStyle(title: "Activity", glyph: "circle.fill", tint: accent)
        }
    }

    private var bodyFont: Font {
        switch event.payload {
        case .commandStarted, .commandFinished, .rawOutput:
            DeckFont.mono
        default:
            DeckFont.body
        }
    }

    private var summary: String {
        switch event.payload {
        case .messageText(let message):
            return message.text
        case .stateChanged(let change):
            return "\(change.from.rawValue) → \(change.to.rawValue)"
        case .toolCallStarted(let call):
            return "\(call.name): \(call.summary)"
        case .toolCallFinished(let result):
            return "\(result.succeeded ? "✓" : "✗") \(result.summary)"
        case .commandStarted(let command):
            return "$ \(command.command)"
        case .commandFinished(let result):
            if let exitCode = result.exitCode {
                return "exit \(exitCode) · \(result.outputSummary)"
            }
            return "killed · \(result.outputSummary)"
        case .fileOperation(let operation):
            return "\(operation.kind.rawValue) \(operation.path)"
        case .diffAvailable(let diff):
            return "Diff: \(diff.filesChanged) files, +\(diff.additions) -\(diff.deletions)"
        case .approvalRequested(let request):
            return request.explanation
        case .approvalResolved(let resolution):
            return "Resolved: \(resolution.decision.choice.rawValue)"
        case .waitingForUser(let question):
            return question.question
        case .plan(let plan):
            if plan.steps.isEmpty {
                return plan.summary
            }
            return plan.summary + "\n" + plan.steps.map { "• \($0)" }.joined(separator: "\n")
        case .fileSearch(let search):
            return "Search “\(search.query)”: \(search.matches.count) match\(search.matches.count == 1 ? "" : "es")"
        case .build(let report):
            return "\(report.succeeded ? "✓" : "✗") Build · \(report.summary)"
        case .test(let report):
            return "\(report.succeeded ? "✓" : "✗") Tests · \(report.passedCount) passed, \(report.failedCount) failed · \(report.summary)"
        case .warning(let warning):
            return "⚠ \(warning.message)"
        case .transport(let notice):
            return notice.message
        case .completed(let result):
            return result.summary
        case .failed(let error):
            return error.message
        case .rawOutput(let raw):
            return raw.text
        @unknown default:
            // Kinds added to the contract after this build render labeled
            // rather than crashing the timeline.
            return event.payload.kind
        }
    }
}

private struct ChatMessageRow: View {
    let message: MessageText
    let date: Date
    let agentName: String
    let agentGlyph: String
    let agentTheme: AgentTheme
    let accent: Color

    var body: some View {
        Group {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 54)
                    VStack(alignment: .trailing, spacing: DeckSpace.xxs) {
                        Text("YOU  /  \(date.formatted(date: .omitted, time: .shortened))")
                            .font(DeckFont.monoSmall.weight(.medium))
                            .foregroundStyle(agentTheme.workspaceText.opacity(0.5))
                        Text(message.text)
                            .font(DeckFont.body)
                            .foregroundStyle(agentTheme.workspaceText)
                            .textSelection(.enabled)
                            .padding(.horizontal, DeckSpace.m)
                            .padding(.vertical, DeckSpace.s)
                            .background(agentTheme.workspaceSurface)
                            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: DeckRadius.hero, style: .continuous)
                                    .stroke(accent.opacity(0.55), lineWidth: 1)
                            }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: DeckSpace.s) {
                    ProviderMark(theme: agentTheme, size: 24)
                    VStack(alignment: .leading, spacing: DeckSpace.xs) {
                        HStack(spacing: DeckSpace.xs) {
                            Text(agentName)
                                .font(DeckFont.monoSmall.weight(.semibold))
                                .foregroundStyle(agentTheme.workspaceText)
                            Rectangle().fill(accent).frame(width: 18, height: 2)
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(agentTheme.workspaceText.opacity(0.38))
                        }
                        Text(message.text)
                            .font(DeckFont.body)
                            .foregroundStyle(agentTheme.workspaceText)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveAgentResponseView: View {
    let text: String
    let isStreaming: Bool
    let agentName: String
    let agentGlyph: String
    let agentTheme: AgentTheme
    let accent: Color
    let onOpenConsole: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DeckSpace.xs) {
            ProviderMark(theme: agentTheme, size: 24, isLive: isStreaming)

            VStack(alignment: .leading, spacing: DeckSpace.s) {
                HStack(spacing: DeckSpace.xs) {
                    Text(agentName)
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .foregroundStyle(agentTheme.workspaceText)
                    if isStreaming {
                        DeckTypingIndicator(color: accent)
                    }
                    Spacer()
                    Button("RAW", systemImage: "terminal") {
                        onOpenConsole()
                    }
                    .font(DeckFont.monoSmall.weight(.medium))
                    .foregroundStyle(agentTheme.workspaceText.opacity(0.52))
                }

                Text(text)
                    .font(DeckFont.body)
                    .foregroundStyle(agentTheme.workspaceText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DeckSpace.s)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(accent).frame(width: 2)
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct EventVisualStyle {
    let title: String
    let glyph: String
    let tint: Color
}
