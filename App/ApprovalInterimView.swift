//
//  ApprovalInterimView.swift
//  App — AgentDeck
//
//  Native provider decision card: preview the exact action, refuse it,
//  accept it once, or remember it for the current agent session. Raw PTY
//  prompts remain a fallback surface rather than the primary interaction.
//

import SwiftUI
import Shared

/// Remaining-time label for approval cards; renders only when the request
/// carries an expiry. Auto-updates via Text's relative style.
struct ApprovalExpiryView: View {
    let expiresAtUnixMilliseconds: Int64

    private var expiryDate: Date {
        Date(unixMilliseconds: expiresAtUnixMilliseconds)
    }

    var body: some View {
        if expiryDate > .now {
            Label {
                Text("Expires in \(expiryDate, style: .relative)")
            } icon: {
                Image(systemName: "clock.badge.exclamationmark")
            }
            .font(DeckFont.footnote)
            .foregroundStyle(DeckColor.warning)
        } else {
            Label("Expired", systemImage: "clock.badge.exclamationmark")
                .font(DeckFont.footnote)
                .foregroundStyle(DeckColor.danger)
        }
    }
}

struct ApprovalInterimView: View {
    let request: ApprovalRequest
    let onResolve: (ApprovalChoice) -> Void

    var body: some View {
        SessionApprovalDock(request: request, onResolve: onResolve)
    }
}

/// Compact approval dock used inside the session work surface. It keeps
/// terminal context visible while the user reviews and resolves a request.
struct SessionApprovalDock: View {
    let request: ApprovalRequest
    var theme: AgentTheme? = nil
    let onResolve: (ApprovalChoice) -> Void
    @State private var isShowingPreview = false

    private var background: Color { theme?.workspaceBackground ?? DeckColor.surface }
    private var surface: Color { theme?.workspaceSurface ?? DeckColor.canvas }
    private var textColor: Color { theme?.workspaceText ?? DeckColor.ink }
    private var actionColor: Color { theme?.accent ?? DeckColor.accent }
    private var ruleColor: Color { theme?.workspaceRule ?? DeckColor.rule }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            HStack(alignment: .top, spacing: DeckSpace.s) {
                HStack(spacing: DeckSpace.xs) {
                    Text("01")
                        .foregroundStyle(actionColor)
                    Text("TRUST GATE")
                        .foregroundStyle(textColor)
                }
                .font(DeckFont.monoSmall.weight(.semibold))
                Spacer()
                ApprovalRiskMeter(risk: request.effectiveRisk, inactiveColor: textColor.opacity(0.14))
                if let expiresAt = request.expiresAt {
                    ApprovalExpiryView(expiresAtUnixMilliseconds: expiresAt)
                        .labelStyle(.iconOnly)
                }
            }

            Text(request.explanation)
                .font(DeckFont.subhead)
                .foregroundStyle(textColor)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DeckSpace.xs) {
                    Text(request.tool.uppercased())
                    Text("/")
                    Text(request.workingDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(textColor.opacity(0.42))

                HStack(alignment: .firstTextBaseline, spacing: DeckSpace.xs) {
                    Text(">")
                        .foregroundStyle(actionColor)
                    Text(request.exactAction)
                        .foregroundStyle(textColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .font(DeckFont.monoSmall)
            }
            .padding(.horizontal, DeckSpace.s)
            .padding(.vertical, DeckSpace.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .overlay(alignment: .leading) { Rectangle().fill(actionColor).frame(width: 2) }

            Text("CHOOSE THE NARROWEST AUTHORITY THAT COMPLETES THE TASK")
                .font(.caption2.monospaced())
                .foregroundStyle(textColor.opacity(0.42))

            Button {
                isShowingPreview = true
            } label: {
                HStack {
                    Label("PREVIEW ACTION", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(DeckFont.monoSmall.weight(.semibold))
                .frame(height: 38)
                .padding(.horizontal, DeckSpace.m)
            }
            .buttonStyle(.plain)
            .foregroundStyle(textColor)
            .background(surface)
            .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(ruleColor, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))

            HStack(spacing: DeckSpace.xs) {
                Button(role: .destructive) {
                    onResolve(.deny)
                } label: {
                    Label("REFUSE", systemImage: "xmark")
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .frame(height: 40)
                        .padding(.horizontal, DeckSpace.m)
                }
                .buttonStyle(.plain)
                .foregroundStyle(textColor)
                .background(surface)
                .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(ruleColor, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))

                Button {
                    onResolve(.allowOnce)
                } label: {
                    HStack {
                        Text("ACCEPT ONCE")
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                        .font(DeckFont.monoSmall.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .padding(.horizontal, DeckSpace.m)
                }
                .buttonStyle(.plain)
                .foregroundStyle(background)
                .background(actionColor)
                .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
            }

            Button {
                onResolve(.allowSession)
            } label: {
                HStack {
                    Label("ALWAYS THIS SESSION", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text("SCOPED")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(textColor.opacity(0.42))
                }
                .font(DeckFont.monoSmall.weight(.semibold))
                .frame(height: 38)
                .padding(.horizontal, DeckSpace.m)
            }
            .buttonStyle(.plain)
            .foregroundStyle(textColor)
            .background(surface)
            .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(ruleColor, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
        }
        .padding(.horizontal, DeckSpace.m)
        .padding(.vertical, DeckSpace.s)
        .background(background)
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                Rectangle().fill(actionColor).frame(maxWidth: .infinity)
                Rectangle().fill(DeckColor.warning).frame(width: 72)
            }
            .frame(height: 3)
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isShowingPreview) {
            ApprovalPreviewSheet(request: request, theme: theme) { choice in
                isShowingPreview = false
                onResolve(choice)
            }
        }
    }
}

/// Full native review surface shared by Codex, Claude, Grok, Kimi, and
/// OpenCode approval requests. Provider payloads are deliberately represented
/// through the common ApprovalRequest contract so client UI never needs to
/// infer permission semantics from terminal pixels.
private struct ApprovalPreviewSheet: View {
    let request: ApprovalRequest
    let theme: AgentTheme?
    let onResolve: (ApprovalChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    private var background: Color { theme?.workspaceBackground ?? DeckColor.surface }
    private var surface: Color { theme?.workspaceSurface ?? DeckColor.canvas }
    private var textColor: Color { theme?.workspaceText ?? DeckColor.ink }
    private var accent: Color { theme?.accent ?? DeckColor.accent }
    private var ruleColor: Color { theme?.workspaceRule ?? DeckColor.rule }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DeckSpace.l) {
                    previewHeader
                    exactActionSection
                    reachSection
                    authoritySection
                }
                .padding(DeckSpace.l)
            }
            .background(background)
            .foregroundStyle(textColor)
            .navigationTitle("Preview action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            HStack {
                Label(request.tool, systemImage: "terminal")
                    .font(DeckFont.headline)
                Spacer()
                ApprovalRiskMeter(risk: request.effectiveRisk, inactiveColor: textColor.opacity(0.14))
            }
            Text(request.explanation)
                .font(DeckFont.subhead)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Reversibility", value: request.reversibility.rawValue.capitalized)
                .font(DeckFont.footnote)
            if let expiresAt = request.expiresAt {
                ApprovalExpiryView(expiresAtUnixMilliseconds: expiresAt)
            }
        }
    }

    private var exactActionSection: some View {
        VStack(alignment: .leading, spacing: DeckSpace.s) {
            sectionLabel("EXACT ACTION")
            Text(request.workingDirectory)
                .font(.caption2.monospaced())
                .foregroundStyle(textColor.opacity(0.48))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: DeckSpace.s) {
                Text(">").foregroundStyle(accent)
                Text(request.exactAction)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DeckFont.mono)
            .padding(DeckSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
            .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3) }
        }
    }

    @ViewBuilder private var reachSection: some View {
        if !request.files.isEmpty || !request.domains.isEmpty {
            VStack(alignment: .leading, spacing: DeckSpace.s) {
                sectionLabel("FILES & NETWORK")
                ForEach(request.files, id: \.self) { file in
                    Label(file, systemImage: "doc")
                }
                ForEach(request.domains, id: \.self) { domain in
                    Label(domain, systemImage: "network")
                }
            }
            .font(DeckFont.monoSmall)
        }
    }

    private var authoritySection: some View {
        VStack(spacing: DeckSpace.s) {
            decisionButton("Refuse", detail: "Do not run this action", symbol: "xmark", color: DeckColor.danger) {
                onResolve(.deny)
            }
            decisionButton("Accept once", detail: "Only this exact request", symbol: "checkmark", color: accent, isPrimary: true) {
                onResolve(.allowOnce)
            }
            decisionButton("Always this session", detail: "Remember until this agent session ends", symbol: "clock.arrow.circlepath", color: textColor) {
                onResolve(.allowSession)
            }
            if request.isReadOnlyOperation {
                decisionButton("Always allow read-only", detail: "Inspection only; never writes or execution", symbol: "eye", color: DeckColor.info) {
                    onResolve(.allowReadOnlyActions)
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DeckFont.monoSmall.weight(.semibold))
            .foregroundStyle(accent)
    }

    private func decisionButton(
        _ title: String,
        detail: String,
        symbol: String,
        color: Color,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DeckSpace.m) {
                Image(systemName: symbol)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DeckFont.callout.weight(.semibold))
                    Text(detail).font(DeckFont.footnote).opacity(0.62)
                }
                Spacer()
            }
            .padding(.horizontal, DeckSpace.m)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPrimary ? background : color)
        .background(isPrimary ? color : surface)
        .overlay { RoundedRectangle(cornerRadius: DeckRadius.card).stroke(isPrimary ? color : ruleColor, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
    }
}

struct ApprovalRiskMeter: View {
    let risk: RiskClassification
    let inactiveColor: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(index < level ? risk.deckColor : inactiveColor)
                        .frame(width: 13, height: 3)
                }
            }
            Text("\(risk.rawValue.uppercased()) RISK")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(risk.deckColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Risk level: \(risk.rawValue)")
    }

    private var level: Int {
        switch risk {
        case .informational: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .critical: 5
        default: 3
        }
    }
}
