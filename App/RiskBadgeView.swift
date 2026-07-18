//
//  RiskBadgeView.swift
//  App — AgentDeck
//
//  §17 risk badge (DESIGN §2.5): never color-only — icon + word + tinted
//  capsule, plus an accessibility label.
//

import SwiftUI
import Shared

struct RiskBadgeView: View {
    let risk: RiskClassification

    var body: some View {
        Label {
            Text(risk.rawValue.capitalized)
                .font(DeckFont.footnote.weight(.semibold))
        } icon: {
            Image(systemName: symbolName)
        }
        .foregroundStyle(risk.deckColor)
        .padding(.horizontal, DeckSpace.xs)
        .padding(.vertical, DeckSpace.xxs)
        .background(risk.deckColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: DeckRadius.chip, style: .continuous))
        .accessibilityLabel("Risk level: \(risk.rawValue)")
    }

    private var symbolName: String {
        switch risk {
        case .informational: "info.circle"
        case .low: "checkmark.circle"
        case .medium: "exclamationmark.circle"
        case .high: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        default:
            // .unknown today; any future classification degrades to a
            // warning glyph rather than a build break.
            "exclamationmark.triangle"
        }
    }
}
