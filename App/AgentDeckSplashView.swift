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
            Color.white.ignoresSafeArea()
            VStack(spacing: 26) {
                AnimatedTerminalMark(phase: phase)
                    .frame(width: 230, height: 230)
                    .accessibilityHidden(true)
                Text("AgentDeck")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(-1.2)
                    .foregroundStyle(.black)
                    .opacity(phase >= .wordmark ? 1 : 0)
                    .offset(y: phase >= .wordmark ? 0 : 10)
                    .blur(radius: phase >= .wordmark ? 0 : 4)
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
        await advance(.spark, 0.20)
        await advance(.frame, 0.50)
        await advance(.prompt, 0.38)
        await advance(.orangeOne, 0.14)
        await advance(.orangeTwo, 0.13)
        await advance(.orangeThree, 0.13)
        await advance(.orangeFour, 0.16)
        await advance(.wordmark, 0.30)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { phase = .settled }
        try? await Task.sleep(for: .milliseconds(650))
        onFinished()
    }
}

private struct AnimatedTerminalMark: View {
    let phase: SplashPhase
    private let ink = Color(red: 0.035, green: 0.035, blue: 0.04)
    private let signal = Color(red: 1, green: 0.28, blue: 0.02)

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.082
            ZStack {
                Circle().fill(signal)
                    .frame(width: size * 0.035, height: size * 0.035)
                    .shadow(color: signal.opacity(0.75), radius: size * 0.06)
                    .scaleEffect(phase == .spark ? 1 : 0.001)
                    .opacity(phase == .spark ? 1 : 0)
                TerminalFrameShape().trim(from: 0, to: phase >= .frame ? 1 : 0)
                    .stroke(ink, style: .init(lineWidth: line, lineCap: .round, lineJoin: .round))
                    .shadow(color: ink.opacity(phase >= .frame ? 0.10 : 0), radius: 8, y: 5)
                PromptChevronShape().trim(from: 0, to: phase >= .prompt ? 1 : 0)
                    .stroke(ink, style: .init(lineWidth: line * 0.72, lineCap: .round, lineJoin: .round))
                Capsule().fill(ink).frame(width: size * 0.23, height: line * 0.72)
                    .offset(x: size * 0.105, y: size * 0.13)
                    .scaleEffect(x: phase >= .prompt ? 1 : 0, anchor: .leading)
                segments(size: size, line: line)
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .scaleEffect(phase == .settled ? 1 : 0.97)
        }
    }

    private func segments(size: CGFloat, line: CGFloat) -> some View {
        let width = line * 0.82
        return Group {
            Capsule().fill(signal).frame(width: width, height: size * 0.17)
                .offset(x: size * 0.39, y: -size * 0.23).reveal(phase >= .orangeOne)
            Capsule().fill(signal).frame(width: width, height: size * 0.17)
                .offset(x: size * 0.39, y: size * 0.01).reveal(phase >= .orangeTwo)
            Capsule().fill(signal).frame(width: size * 0.17, height: width)
                .offset(x: size * 0.16, y: size * 0.39).reveal(phase >= .orangeThree)
            BottomRightCornerShape()
                .stroke(signal, style: .init(lineWidth: width, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.23, height: size * 0.23)
                .offset(x: size * 0.31, y: size * 0.31).reveal(phase >= .orangeFour)
        }
    }
}

private extension View {
    func reveal(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).scaleEffect(visible ? 1 : 0.35).blur(radius: visible ? 0 : 5)
    }
}

private enum SplashPhase: Int, Comparable {
    case idle, spark, frame, prompt, orangeOne, orangeTwo, orangeThree, orangeFour, wordmark, settled
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct TerminalFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let minX = rect.minX + rect.width * 0.17, maxX = rect.maxX - rect.width * 0.12
        let minY = rect.minY + rect.height * 0.17, maxY = rect.maxY - rect.height * 0.18
        let radius = rect.width * 0.10
        var path = Path()
        path.move(to: .init(x: maxX, y: minY)); path.addLine(to: .init(x: minX + radius, y: minY))
        path.addQuadCurve(to: .init(x: minX, y: minY + radius), control: .init(x: minX, y: minY))
        path.addLine(to: .init(x: minX, y: maxY - radius))
        path.addQuadCurve(to: .init(x: minX + radius, y: maxY), control: .init(x: minX, y: maxY))
        path.addLine(to: .init(x: rect.midX + rect.width * 0.05, y: maxY)); return path
    }
}

private struct PromptChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: .init(x: rect.width * 0.37, y: rect.height * 0.39))
        path.addLine(to: .init(x: rect.width * 0.52, y: rect.height * 0.50))
        path.addLine(to: .init(x: rect.width * 0.37, y: rect.height * 0.61)); return path
    }
}

private struct BottomRightCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: .init(x: rect.minX, y: rect.maxY))
        path.addLine(to: .init(x: rect.maxX * 0.52, y: rect.maxY))
        path.addQuadCurve(to: .init(x: rect.maxX, y: rect.maxY * 0.52), control: .init(x: rect.maxX, y: rect.maxY))
        path.addLine(to: .init(x: rect.maxX, y: rect.minY)); return path
    }
}
