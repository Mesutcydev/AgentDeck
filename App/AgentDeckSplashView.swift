import SwiftUI

/// Animated cold-launch signature supplied for AgentDeck. The main app remains
/// mounted behind it, so networking and session restoration start immediately.
struct AgentDeckSplashView: View {
    let onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = SplashPhase.idle
    @State private var started = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                AnimatedTerminalMark(phase: phase)
                    .frame(width: 220, height: 220)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Text("AGENT")
                        .foregroundStyle(.white)
                    Text("/DECK")
                        .foregroundStyle(Color(red: 1, green: 0.28, blue: 0.02))
                }
                    .font(.system(size: 31, weight: .black, design: .default))
                    .tracking(-0.9)
                    .opacity(phase >= .wordmark ? 1 : 0)
                    .offset(y: phase >= .wordmark ? 0 : 8)
            }
            .scaleEffect(phase == .settled ? 1 : 0.985)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("AgentDeck")
        .onAppear {
            guard !started else { return }
            started = true
            Task { await animate() }
        }
    }

    @MainActor private func advance(_ next: SplashPhase, _ duration: Double) async {
        if reduceMotion {
            phase = next
            try? await Task.sleep(for: .milliseconds(55))
        } else {
            withAnimation(.smooth(duration: duration)) { phase = next }
            try? await Task.sleep(for: .seconds(duration))
        }
    }

    @MainActor private func animate() async {
        if reduceMotion {
            phase = .settled
            try? await Task.sleep(for: .milliseconds(450))
            onFinished()
            return
        }
        try? await Task.sleep(for: .milliseconds(140))
        await advance(.frame, 0.48)
        await advance(.prompt, 0.30)
        await advance(.orangeOne, 0.16)
        await advance(.orangeTwo, 0.14)
        await advance(.orangeThree, 0.14)
        await advance(.orangeFour, 0.20)
        await advance(.wordmark, 0.30)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { phase = .settled }
        try? await Task.sleep(for: .milliseconds(650))
        onFinished()
    }
}

private struct AnimatedTerminalMark: View {
    let phase: SplashPhase
    private let ink = Color.white
    private let signal = Color(red: 1, green: 0.28, blue: 0.02)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.066
            ZStack {
                TerminalFrameShape().trim(from: 0, to: phase >= .frame ? 1 : 0)
                    .stroke(ink, style: .init(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .shadow(color: ink.opacity(phase >= .frame ? 0.10 : 0), radius: 8, y: 5)
                PromptChevronShape().trim(from: 0, to: phase >= .prompt ? 1 : 0)
                    .stroke(ink, style: .init(lineWidth: line * 0.72, lineCap: .round, lineJoin: .round))
                Capsule().fill(ink).frame(width: size * 0.18, height: line * 0.72)
                    .offset(x: size * 0.10, y: size * 0.135)
                    .scaleEffect(x: phase >= .prompt ? 1 : 0, anchor: .leading)
                segments(size: size, line: line)
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .scaleEffect(phase == .settled ? 1 : 0.97)
        }
    }

    private func segments(size: CGFloat, line: CGFloat) -> some View {
        let width = line
        return Group {
            TopRightRailShape().trim(from: 0, to: phase >= .orangeOne ? 1 : 0)
                .stroke(signal, style: .init(lineWidth: width, lineCap: .round, lineJoin: .round))
            Capsule().fill(signal).frame(width: width, height: size * 0.13)
                .offset(x: size * 0.355, y: -size * 0.015).reveal(phase >= .orangeTwo)
            Capsule().fill(signal).frame(width: width, height: size * 0.13)
                .offset(x: size * 0.355, y: size * 0.205).reveal(phase >= .orangeThree)
            BottomRightRailShape()
                .trim(from: 0, to: phase >= .orangeFour ? 1 : 0)
                .stroke(signal, style: .init(lineWidth: width, lineCap: .round, lineJoin: .round))
                .reveal(phase >= .orangeFour)
        }
    }
}

private extension View {
    func reveal(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).blur(radius: visible ? 0 : 3)
    }
}

private enum SplashPhase: Int, Comparable {
    case idle, frame, prompt, orangeOne, orangeTwo, orangeThree, orangeFour, wordmark, settled
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct TerminalFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let minX = rect.width * 0.17, maxX = rect.width * 0.64
        let minY = rect.height * 0.16, maxY = rect.height * 0.84
        let radius = rect.width * 0.085
        var path = Path()
        path.move(to: .init(x: maxX, y: minY)); path.addLine(to: .init(x: minX + radius, y: minY))
        path.addQuadCurve(to: .init(x: minX, y: minY + radius), control: .init(x: minX, y: minY))
        path.addLine(to: .init(x: minX, y: maxY - radius))
        path.addQuadCurve(to: .init(x: minX + radius, y: maxY), control: .init(x: minX, y: maxY))
        path.addLine(to: .init(x: rect.width * 0.56, y: maxY)); return path
    }
}

private struct PromptChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: .init(x: rect.width * 0.35, y: rect.height * 0.39))
        path.addLine(to: .init(x: rect.width * 0.51, y: rect.height * 0.50))
        path.addLine(to: .init(x: rect.width * 0.35, y: rect.height * 0.61)); return path
    }
}

private struct TopRightRailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: rect.width * 0.72, y: rect.height * 0.16))
        path.addLine(to: .init(x: rect.width * 0.79, y: rect.height * 0.16))
        path.addQuadCurve(to: .init(x: rect.width * 0.86, y: rect.height * 0.23), control: .init(x: rect.width * 0.86, y: rect.height * 0.16))
        path.addLine(to: .init(x: rect.width * 0.86, y: rect.height * 0.29))
        return path
    }
}

/// One continuous rail owns the entire orange bottom/right junction. Keeping
/// it in one path prevents separate rounded stroke caps from ever colliding.
private struct BottomRightRailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: rect.width * 0.86, y: rect.height * 0.72))
        path.addLine(to: .init(x: rect.width * 0.86, y: rect.height * 0.77))
        path.addQuadCurve(
            to: .init(x: rect.width * 0.79, y: rect.height * 0.84),
            control: .init(x: rect.width * 0.86, y: rect.height * 0.84)
        )
        path.addLine(to: .init(x: rect.width * 0.65, y: rect.height * 0.84))
        return path
    }
}
