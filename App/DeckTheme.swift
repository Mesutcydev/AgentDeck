//
//  DeckTheme.swift
//  App — AgentDeck
//
//  Design-system tokens (docs/DESIGN.md). Views consume these values and
//  never raw numbers: spacing on the 4 pt grid, continuous radii,
//  Dynamic Type scale, per-agent themes, motion springs, and haptics.
//

import SwiftUI
import Shared
import UIKit

// MARK: - Spacing (§2.1, 4 pt grid)

enum DeckSpace {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 16
    static let m: CGFloat = 24
    static let l: CGFloat = 32
    static let xl: CGFloat = 48
    static let xxl: CGFloat = 64
}

// MARK: - Corner radii (§2.2, continuous)

enum DeckRadius {
    static let chip: CGFloat = 6
    static let card: CGFloat = 16
    static let hero: CGFloat = 16
    static let sheet: CGFloat = 20
}

// MARK: - Type scale (§2.3)

enum DeckFont {
    static let display = Font.system(size: 36, weight: .bold, design: .default)
    static let title = Font.system(.title, design: .default).weight(.bold)
    static let headline = Font.system(.title2, design: .default).weight(.semibold)
    static let subhead = Font.system(.title3, design: .default).weight(.semibold)
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.subheadline
    static let footnote = Font.footnote
    static let mono = Font.system(size: 13, design: .monospaced)
    static let monoSmall = Font.system(size: 12, design: .monospaced)
}

struct DeckSectionHeader: View {
    let eyebrow: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.96)
                    .foregroundStyle(.secondary)
                Text(title).font(.system(size: 22, weight: .bold))
            }
            Spacer()
            if let trailing { Text(trailing).font(DeckFont.monoSmall).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Color (§2.5)

extension Color {
    /// Hex literal (RRGGBB). Design tokens only — never a view-local value.
    init(deckHex: UInt64) {
        let red = Double((deckHex >> 16) & 0xFF) / 255
        let green = Double((deckHex >> 8) & 0xFF) / 255
        let blue = Double(deckHex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    static func deckAdaptive(light: UInt64, dark: UInt64) -> Color {
        Color(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            let red = CGFloat((value >> 16) & 0xFF) / 255
            let green = CGFloat((value >> 8) & 0xFF) / 255
            let blue = CGFloat(value & 0xFF) / 255
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        })
    }
}

enum DeckColor {
    /// AgentDeck is monochrome-first. Signal orange is reserved for live
    /// state and primary action; provider color belongs to provider content.
    static let ink = Color.deckAdaptive(light: 0x111111, dark: 0xF2F1ED)
    static let canvas = Color.deckAdaptive(light: 0xF3F2EE, dark: 0x10100F)
    static let surface = Color.deckAdaptive(light: 0xFAF9F6, dark: 0x181817)
    static let surfaceRaised = Color.deckAdaptive(light: 0xE9E8E3, dark: 0x242422)
    static let rule = Color.deckAdaptive(light: 0xD5D3CC, dark: 0x383834)
    static let accent = Color.deckAdaptive(light: 0xF24B2A, dark: 0xFF6A48)
    static let accentDeep = Color.deckAdaptive(light: 0xBD2D13, dark: 0xFF8B72)
    static let signal = Color.deckAdaptive(light: 0xF24B2A, dark: 0xFF6A48)
    static let success = Color.deckAdaptive(light: 0x248A3D, dark: 0x30D158)
    static let warning = Color.deckAdaptive(light: 0xC66A00, dark: 0xFFD60A)
    static let danger = Color.deckAdaptive(light: 0xD70015, dark: 0xFF453A)
    static let info = Color.deckAdaptive(light: 0x0066CC, dark: 0x64D2FF)

    static let brandGradient = LinearGradient(colors: [accent, accent], startPoint: .leading, endPoint: .trailing)
}

// MARK: - AgentDeck brand primitives

/// A slotted A/D monogram built from rails. It stays crisp at toolbar sizes
/// and avoids the stacked-card language common to AI products.
struct DeckMark: View {
    var size: CGFloat = 32
    var color: Color = DeckColor.accent
    var showsSignal = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            HStack(spacing: size * 0.13) {
                Rectangle().fill(color).frame(width: size * 0.11, height: size * 0.72)
                ZStack {
                    Rectangle()
                        .fill(color)
                        .frame(width: size * 0.11, height: size * 0.76)
                        .rotationEffect(.degrees(-34))
                    Rectangle()
                        .fill(color)
                        .frame(width: size * 0.11, height: size * 0.76)
                        .rotationEffect(.degrees(34))
                }
                .frame(width: size * 0.42, height: size * 0.72)
                Rectangle().fill(color).frame(width: size * 0.11, height: size * 0.72)
            }
            if showsSignal {
                Circle()
                    .fill(color)
                    .frame(width: size * 0.14, height: size * 0.14)
                    .scaleEffect(isPulsing ? 1.12 : 0.84)
                    .opacity(isPulsing ? 1 : 0.55)
                    .offset(x: size * 0.42, y: -size * 0.40)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task {
            guard showsSignal, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

struct DeckCanvas: View {
    var body: some View {
        DeckColor.canvas.ignoresSafeArea()
    }
}

private struct DeckSurfaceModifier: ViewModifier {
    let accent: Color?
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(DeckColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(alignment: .leading) {
                if let accent {
                    Rectangle()
                        .fill(accent)
                        .frame(width: 2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(DeckColor.rule, lineWidth: 0.75)
            }
    }
}

extension View {
    func deckSurface(accent: Color? = nil, radius: CGFloat = DeckRadius.card) -> some View {
        modifier(DeckSurfaceModifier(accent: accent, radius: radius))
    }
}

struct DeckActionButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? DeckColor.canvas : DeckColor.ink)
            .background(primary ? DeckColor.ink : DeckColor.surface)
            .overlay {
                RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous)
                    .stroke(primary ? Color.clear : DeckColor.rule, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: DeckRadius.card, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(DeckMotion.quick, value: configuration.isPressed)
    }
}

/// A ledger-like empty state that stays inside the precision-console visual
/// language instead of falling back to a plain white List row.
struct DeckEmptyLedger: View {
    let index: String
    let title: String
    let detail: String
    let systemImage: String
    var accent: Color = DeckColor.accent

    var body: some View {
        HStack(spacing: DeckSpace.m) {
            VStack(spacing: 3) {
                Text(index)
                    .font(.caption2.monospaced().weight(.bold))
                Rectangle().fill(accent).frame(width: 18, height: 2)
            }
            .foregroundStyle(accent)
            .frame(width: 28)
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DeckColor.ink.opacity(0.62))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(DeckFont.monoSmall.weight(.semibold))
                    .foregroundStyle(DeckColor.ink)
                Text(detail)
                    .font(DeckFont.footnote)
                    .foregroundStyle(DeckColor.ink.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeckSpace.m)
        .frame(minHeight: 72)
        .background(DeckColor.surfaceRaised)
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3) }
        .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 1) }
    }
}

struct DeckSectionLabel: View {
    let title: String
    var eyebrow: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: DeckSpace.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(DeckFont.monoSmall.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(DeckFont.subhead)
                    .foregroundStyle(DeckColor.ink)
            }
            Spacer()
        }
    }
}

struct DeckPageHeader: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: DeckSpace.xs) {
            HStack {
                Text(index)
                    .font(DeckFont.monoSmall.weight(.semibold))
                    .foregroundStyle(DeckColor.accent)
                Spacer()
                DeckMark(size: 18, color: DeckColor.ink, showsSignal: false)
            }
            Text(title)
                .font(DeckFont.title)
                .tracking(-0.6)
            Text(detail)
                .font(DeckFont.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DeckSpace.m)
        .overlay(alignment: .top) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
        .overlay(alignment: .bottom) { Rectangle().fill(DeckColor.rule).frame(height: 0.75) }
    }
}

// MARK: - Risk colors (§2.5 mapping; icon + text twin lives in RiskBadgeView)

extension RiskClassification {
    var deckColor: Color {
        switch self {
        case .informational: DeckColor.info
        case .low: DeckColor.success
        case .medium, .high: DeckColor.warning
        case .critical: DeckColor.danger
        default: .secondary
        }
    }
}

// MARK: - Agent themes (§3)

struct AgentTheme: Sendable {
    /// Catalog raw id this theme matches ("generic" for the fallback).
    let matchID: String
    let accent: Color
    let secondaryAccent: Color
    let assetName: String?
    let terminalBackground: Color
    let terminalText: Color
    /// SF Symbol name.
    let glyph: String
    /// One-word voice used in empty states.
    let personality: String

    var usesProviderSkin: Bool { matchID != "generic" }
    var workspaceBackground: Color { usesProviderSkin ? terminalBackground : DeckColor.canvas }
    var workspaceText: Color { usesProviderSkin ? terminalText : DeckColor.ink }
    var workspaceSurface: Color {
        usesProviderSkin ? terminalText.opacity(0.055) : DeckColor.surface
    }
    var workspaceRule: Color {
        usesProviderSkin ? terminalText.opacity(0.18) : DeckColor.rule
    }
}

enum AgentThemes {
    static let claude = AgentTheme(
        matchID: "com.anthropic.claude-code",
        accent: Color(deckHex: 0xD97757),
        secondaryAccent: Color(deckHex: 0xF3B39D),
        assetName: "ProviderClaude",
        terminalBackground: Color(deckHex: 0x202633),
        terminalText: Color(deckHex: 0xF1F1F0),
        glyph: "asterisk",
        personality: "Thoughtful"
    )
    static let codex = AgentTheme(
        matchID: "com.openai.codex",
        accent: Color(deckHex: 0x10A37F),
        secondaryAccent: Color(deckHex: 0x7FE2C7),
        assetName: "ProviderOpenAI",
        terminalBackground: Color(deckHex: 0x0D1117),
        terminalText: Color(deckHex: 0xE6EDF3),
        glyph: "chevron.left.forwardslash.chevron.right",
        personality: "Precise"
    )
    static let kimi = AgentTheme(
        matchID: "com.moonshot.kimi",
        accent: Color(deckHex: 0x4C8DFF),
        secondaryAccent: Color(deckHex: 0x9CC5FF),
        assetName: "ProviderKimi",
        terminalBackground: Color(deckHex: 0x202633),
        terminalText: Color(deckHex: 0xDCE6FF),
        glyph: "moon.stars.fill",
        personality: "Calm"
    )
    static let grok = AgentTheme(
        matchID: "com.xai.grok",
        accent: Color(deckHex: 0xE6A94F),
        secondaryAccent: Color(deckHex: 0x7A7A7A),
        assetName: "ProviderGrok",
        terminalBackground: Color(deckHex: 0x000000),
        terminalText: Color(deckHex: 0xFAFAFA),
        glyph: "bolt.fill",
        personality: "Direct"
    )
    static let openCode = AgentTheme(
        matchID: "com.anomaly.opencode",
        accent: Color(deckHex: 0x00C8CE),
        secondaryAccent: Color(deckHex: 0xFFB547),
        assetName: "ProviderOpenCode",
        terminalBackground: Color(deckHex: 0x080909),
        terminalText: Color(deckHex: 0xD9F5F0),
        glyph: "curlybraces",
        personality: "Open"
    )
    static let generic = AgentTheme(
        matchID: "generic",
        accent: DeckColor.accent,
        secondaryAccent: Color(deckHex: 0xAAA3FF),
        assetName: nil,
        terminalBackground: Color(deckHex: 0x101014),
        terminalText: Color(deckHex: 0xEDEDF2),
        glyph: "terminal.fill",
        personality: "Ready"
    )

    private static let all: [AgentTheme] = [claude, codex, kimi, grok, openCode]

    /// Theme for a known agent; anything else (including shell PTYs and
    /// agents added to the catalog later) falls back to `generic`.
    static func theme(for agent: AgentIdentifier?) -> AgentTheme {
        guard let agent else { return generic }
        return all.first { $0.matchID == agent.rawValue } ?? generic
    }
}

/// Provider marks are unboxed glyphs, never generic app-icon thumbnails.
struct ProviderMark: View {
    let theme: AgentTheme
    var size: CGFloat = 32
    var isLive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathes = false

    var body: some View {
        ZStack {
            if let assetName = theme.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                genericPromptMark
            }
            if isLive {
                Circle()
                    .fill(theme.accent)
                    .frame(width: max(5, size * 0.17), height: max(5, size * 0.17))
                    .opacity(breathes ? 1 : 0.38)
                    .scaleEffect(breathes ? 1 : 0.78)
                    .offset(x: size * 0.42, y: -size * 0.42)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathes = true
            }
        }
    }

    private var genericPromptMark: some View {
        HStack(spacing: size * 0.08) {
            Rectangle().fill(theme.accent).frame(width: size * 0.11, height: size * 0.50).rotationEffect(.degrees(-40))
            Rectangle().fill(theme.accent).frame(width: size * 0.38, height: size * 0.09)
        }
    }
}

struct ProviderWatermark: View {
    let theme: AgentTheme

    var body: some View {
        EmptyView()
    }
}

/// Branded three-dot stream indicator; subtle movement communicates that the
/// provider is actively producing text without a generic spinner.
struct DeckTypingIndicator: View {
    var color: Color = DeckColor.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            dots(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 0.18)) { context in
                dots(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(at time: TimeInterval) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                let wave = (sin(time * 4.0 - Double(index) * 0.9) + 1) / 2
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.72 + wave * 0.38)
                    .opacity(0.45 + wave * 0.55)
            }
        }
        .frame(width: 24, height: 14)
        .accessibilityLabel("Streaming")
    }
}

// MARK: - Motion (§5)

enum DeckMotion {
    static let quick = Animation.spring(duration: 0.25, bounce: 0.0)
    static let standard = Animation.spring(duration: 0.35, bounce: 0.15)
    static let emphasis = Animation.spring(duration: 0.5, bounce: 0.25)

    /// Card/list insertion; collapses to opacity under Reduce Motion.
    static func appearance(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98))
    }
}

// MARK: - Haptics (§6)

@MainActor
enum DeckHaptics {
    /// Soft impact for sends (prompt, terminal enter).
    static func send() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }

    /// Rigid tick for manual reconnects.
    static func retry() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
    }

    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35)
    }

    /// Hold-to-confirm progress tick; ramps 0.3 → 0.8 across progress.
    static func holdTick(progress: Double) {
        let clamped = min(max(progress, 0), 1)
        UIImpactFeedbackGenerator(style: .light)
            .impactOccurred(intensity: 0.3 + 0.5 * clamped)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
