import SwiftUI
import Shared

enum CompanionDeckColor {
    static let canvas = Color(red: 0.965, green: 0.958, blue: 0.935)
    static let surface = Color(red: 0.925, green: 0.918, blue: 0.895)
    static let ink = Color(red: 0.055, green: 0.055, blue: 0.052)
    static let muted = ink.opacity(0.48)
    static let rule = ink.opacity(0.15)
    static let signal = Color(red: 1.0, green: 0.27, blue: 0.14)
    static let success = Color(red: 0.08, green: 0.52, blue: 0.24)
    static let warning = Color(red: 0.88, green: 0.55, blue: 0.08)
    static let danger = Color(red: 0.82, green: 0.08, blue: 0.12)
}

enum CompanionDeckFont {
    static let display = Font.system(size: 38, weight: .black, design: .default)
    static let title = Font.system(size: 24, weight: .bold, design: .default)
    static let body = Font.system(size: 13, weight: .regular, design: .default)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

struct CompanionDeckMark: View {
    var size: CGFloat = 28
    var color = CompanionDeckColor.signal

    var body: some View {
        HStack(spacing: size * 0.08) {
            Rectangle().frame(width: size * 0.12, height: size * 0.72)
            Text(">")
                .font(.system(size: size * 0.55, weight: .black, design: .monospaced))
            Rectangle().frame(width: size * 0.12, height: size * 0.72)
        }
        .foregroundStyle(color)
        .frame(width: size * 1.25, height: size)
        .accessibilityLabel("AgentDeck")
    }
}

struct CompanionLiveSignal: View {
    var color = CompanionDeckColor.success
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let pulse = (sin(phase * 2.4) + 1) / 2
            ZStack {
                Circle()
                    .stroke(color.opacity(0.38 * (1 - pulse)), lineWidth: 1)
                    .frame(width: size + 5 + (pulse * 7), height: size + 5 + (pulse * 7))
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(0.76 + (pulse * 0.24))
            }
            .frame(width: size + 14, height: size + 14)
        }
        .accessibilityHidden(true)
    }
}

struct CompanionScanLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let elapsed = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
                let progress = reduceMotion ? 0.0 : elapsed.truncatingRemainder(dividingBy: 5.5) / 5.5
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, CompanionDeckColor.signal.opacity(0.75), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 72, height: 2)
                    .offset(x: (proxy.size.width + 72) * progress - 72)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct CompanionPageHeader: View {
    let index: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(index)
                    .font(CompanionDeckFont.label)
                    .foregroundStyle(CompanionDeckColor.signal)
                Spacer()
                CompanionDeckMark(size: 24)
            }
            Text(title)
                .font(CompanionDeckFont.display)
                .foregroundStyle(CompanionDeckColor.ink)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(CompanionDeckColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(CompanionDeckColor.rule).frame(height: 1) }
    }
}

struct CompanionSectionLabel: View {
    let index: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(index).foregroundStyle(CompanionDeckColor.signal)
            Text(title.uppercased()).foregroundStyle(CompanionDeckColor.ink)
        }
        .font(CompanionDeckFont.label)
    }
}

struct CompanionActionStyle: ButtonStyle {
    var primary = false
    var tint = CompanionDeckColor.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompanionDeckFont.label)
            .foregroundStyle(primary ? CompanionDeckColor.canvas : tint)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(primary ? tint : CompanionDeckColor.surface)
            .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
            .overlay { Rectangle().stroke(primary ? tint : CompanionDeckColor.rule, lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

struct CompanionStatusPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title.uppercased())
            }
            .font(CompanionDeckFont.label)
            .foregroundStyle(CompanionDeckColor.muted)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundStyle(CompanionDeckColor.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionDeckColor.surface)
        .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 2) }
    }
}

struct CompanionProviderTheme {
    let name: String
    let assetName: String?
    let accent: Color

    static func resolve(_ id: AgentIdentifier) -> CompanionProviderTheme {
        switch id.rawValue {
        case "com.anthropic.claude-code": .init(name: "Claude", assetName: "ProviderClaude", accent: Color(red: 0.86, green: 0.40, blue: 0.25))
        case "com.openai.codex": .init(name: "Codex", assetName: "ProviderOpenAI", accent: Color(red: 0.12, green: 0.50, blue: 0.32))
        case "com.xai.grok": .init(name: "Grok", assetName: "ProviderGrok", accent: Color(red: 0.90, green: 0.66, blue: 0.31))
        case "com.moonshot.kimi": .init(name: "Kimi", assetName: "ProviderKimi", accent: Color(red: 0.20, green: 0.55, blue: 1.0))
        case "com.anomaly.opencode": .init(name: "OpenCode", assetName: "ProviderOpenCode", accent: Color(red: 0.0, green: 0.70, blue: 0.73))
        default: .init(name: AgentCatalog.descriptor(for: id)?.displayName ?? id.rawValue, assetName: nil, accent: CompanionDeckColor.signal)
        }
    }
}

struct CompanionProviderMark: View {
    let agent: AgentIdentifier
    var size: CGFloat = 32

    var body: some View {
        let theme = CompanionProviderTheme.resolve(agent)
        Group {
            if let assetName = theme.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else {
                CompanionDeckMark(size: size * 0.65, color: theme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(CompanionDeckColor.rule, lineWidth: 1) }
    }
}
