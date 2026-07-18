import SwiftUI

/// A restrained, continuous status marquee. It only moves when the content
/// actually overflows and becomes static when Reduce Motion is enabled.
struct DeckMarqueeText: View {
    let text: String
    var speed: CGFloat = 24
    var gap: CGFloat = 42

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let overflowing = textWidth > geometry.size.width
            Group {
                if overflowing && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let elapsed = context.date.timeIntervalSinceReferenceDate
                        let travel = textWidth + gap
                        let offset = -CGFloat((elapsed * Double(speed)).truncatingRemainder(dividingBy: Double(travel)))
                        HStack(spacing: gap) {
                            marqueeLabel
                            marqueeLabel
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: offset)
                    }
                } else {
                    marqueeLabel
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: overflowing ? 0.035 : 0),
                        .init(color: .black, location: overflowing ? 0.94 : 1),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(height: 20)
        .background {
            marqueeLabel
                .fixedSize()
                .hidden()
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { textWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { textWidth = $1 }
                    }
                }
        }
        .accessibilityLabel(text)
    }

    private var marqueeLabel: some View {
        Text(text)
            .font(DeckFont.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }
}
