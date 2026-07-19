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
        Image(systemName: state.remoteAccessPaused ? "terminal.fill" : "terminal")
            .symbolRenderingMode(.monochrome)
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
