//
//  CompanionApp.swift
//  Companion — AgentDeck
//
//  §12.1 shell: MenuBarExtra status item, one-time onboarding window,
//  native Settings scene. No permanent dashboard; accessory activation
//  policy after onboarding (no Dock icon).
//

import SwiftUI
import Shared

@main
struct CompanionApp: App {
    @State private var appState = AppState.makeDefault()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(state: appState)
                .preferredColorScheme(.light)
        } label: {
            MenuBarLabelView(state: appState)
        }
        .menuBarExtraStyle(.window)

        Window("Session Memory", id: "sessions") {
            SessionMemoryView(state: appState)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 880, height: 620)

        Window("Welcome to \(ProductNaming.name)", id: "onboarding") {
            OnboardingView(state: appState)
                .preferredColorScheme(.light)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(state: appState)
                .preferredColorScheme(.light)
        }

        Window("Pair Device", id: "pairing") {
            PairingWindowView(state: appState)
                .preferredColorScheme(.light)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Import Terminal Session", id: "import-session") {
            ImportSessionView(state: appState)
                .preferredColorScheme(.light)
        }
        .defaultSize(width: 720, height: 560)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// The status-item label. Created eagerly at launch, so it also drives
/// startup: apply the activation policy, load counts, and open the
/// one-time onboarding window when needed.
struct MenuBarLabelView: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AgentDeckMenuBarGlyph(paused: state.remoteAccessPaused)
            .frame(width: 19, height: 18)
            .accessibilityLabel(state.remoteAccessPaused ? "AgentDeck paused" : "AgentDeck")
            .task {
                await state.start()
                if !state.onboardingCompleted, !AppState.isRunningTests {
                    openWindow(id: "onboarding")
                }
            }
            .onChange(of: state.pairingWindowOpen) { _, open in
                if open {
                    openWindow(id: "pairing")
                    state.closePairingWindow()
                }
            }
            .onChange(of: state.importWindowOpen) { _, open in
                if open {
                    openWindow(id: "import-session")
                    state.closeImportWindow()
                }
            }
    }
}

/// A menu-bar-specific reduction of the AgentDeck mark. It is deliberately
/// drawn as a template glyph rather than reusing the full-color app artwork:
/// macOS can therefore tint it correctly for every menu-bar appearance while
/// the terminal prompt and broken right rail remain identifiable at 18 points.
private struct AgentDeckMenuBarGlyph: View {
    let paused: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let stroke = max(1.35, size * 0.105)
            ZStack {
                MenuBarTerminalOutline()
                    .stroke(.primary, style: .init(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                MenuBarPrompt()
                    .stroke(.primary, style: .init(lineWidth: stroke * 0.86, lineCap: .round, lineJoin: .round))
                if paused {
                    HStack(spacing: stroke * 0.72) {
                        Capsule().fill(.primary)
                        Capsule().fill(.primary)
                    }
                    .frame(width: size * 0.31, height: size * 0.30)
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: size * 0.29, y: size * 0.29)
                }
            }
            .frame(width: size, height: size)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

private struct MenuBarTerminalOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: rect.width * 0.61, y: rect.height * 0.13))
        path.addLine(to: .init(x: rect.width * 0.22, y: rect.height * 0.13))
        path.addQuadCurve(to: .init(x: rect.width * 0.13, y: rect.height * 0.22), control: .init(x: rect.width * 0.13, y: rect.height * 0.13))
        path.addLine(to: .init(x: rect.width * 0.13, y: rect.height * 0.78))
        path.addQuadCurve(to: .init(x: rect.width * 0.22, y: rect.height * 0.87), control: .init(x: rect.width * 0.13, y: rect.height * 0.87))
        path.addLine(to: .init(x: rect.width * 0.56, y: rect.height * 0.87))

        path.move(to: .init(x: rect.width * 0.72, y: rect.height * 0.13))
        path.addLine(to: .init(x: rect.width * 0.80, y: rect.height * 0.13))
        path.addQuadCurve(to: .init(x: rect.width * 0.87, y: rect.height * 0.20), control: .init(x: rect.width * 0.87, y: rect.height * 0.13))
        path.addLine(to: .init(x: rect.width * 0.87, y: rect.height * 0.29))
        path.move(to: .init(x: rect.width * 0.87, y: rect.height * 0.42))
        path.addLine(to: .init(x: rect.width * 0.87, y: rect.height * 0.54))
        path.move(to: .init(x: rect.width * 0.87, y: rect.height * 0.67))
        path.addLine(to: .init(x: rect.width * 0.87, y: rect.height * 0.78))
        path.addQuadCurve(to: .init(x: rect.width * 0.78, y: rect.height * 0.87), control: .init(x: rect.width * 0.87, y: rect.height * 0.87))
        path.addLine(to: .init(x: rect.width * 0.69, y: rect.height * 0.87))
        return path
    }
}

private struct MenuBarPrompt: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .init(x: rect.width * 0.34, y: rect.height * 0.38))
        path.addLine(to: .init(x: rect.width * 0.51, y: rect.height * 0.50))
        path.addLine(to: .init(x: rect.width * 0.34, y: rect.height * 0.62))
        path.move(to: .init(x: rect.width * 0.53, y: rect.height * 0.65))
        path.addLine(to: .init(x: rect.width * 0.66, y: rect.height * 0.65))
        return path
    }
}
