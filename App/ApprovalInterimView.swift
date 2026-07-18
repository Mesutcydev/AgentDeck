//
//  ApprovalInterimView.swift
//  App — AgentDeck
//
//  Timeline approval card (DESIGN §7.5 hero card): Deny / Allow Once,
//  risk badge, and expiry, tokenized. Resolution haptics fire in the
//  session view that owns the choice.
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

            Text("ALLOW ONCE · THIS RUN ONLY · NO RULE SAVED")
                .font(.caption2.monospaced())
                .foregroundStyle(textColor.opacity(0.42))

            HStack(spacing: DeckSpace.xs) {
                Button(role: .destructive) {
                    onResolve(.deny)
                } label: {
                    Label("DENY", systemImage: "xmark")
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
                        Text("ALLOW ONCE")
                        Spacer()
                        Image(systemName: "arrow.right")
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
