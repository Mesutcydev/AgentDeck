//
//  AgentDeckApp.swift
//  App — AgentDeck
//
//  §13 iOS/iPadOS app entry point. Phase 3 ships a minimal device list and
//  pairing flow; later phases add sessions, approvals, and settings.
//

import SwiftUI
import Shared

@main
struct AgentDeckApp: App {
    @State private var appState = IOSAppState.makeDefault()
    @State private var pushManager: PushNotificationManager?
    @State private var didRequestPushAuthorization = false
    @State private var showsSplash = true
    @AppStorage("iosOnboardingAcceptedV1") private var onboardingAccepted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showsSplash {
                    AgentDeckSplashView {
                        withAnimation(.easeOut(duration: 0.28)) { showsSplash = false }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.015)))
                    .zIndex(10)
                } else if !onboardingAccepted {
                    IOSOnboardingView { onboardingAccepted = true }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(9)
                } else {
                    MainTabView(state: appState)
                        .transition(.opacity)
                }
            }
                .task {
                    if pushManager == nil {
                        let manager = PushNotificationManager(appState: appState)
                        pushManager = manager
                        manager.configure()
                    }
                    // §14 UX: push permission is requested only once at
                    // least one Mac is paired — notifications mean nothing
                    // before then, and a cold-launch prompt teaches users
                    // to reflexively deny.
                    requestPushAuthorizationIfPaired()
                }
                .onChange(of: appState.pairedDevices) { _, _ in
                    requestPushAuthorizationIfPaired()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { await appState.handleScenePhase(Self.mapPhase(newPhase)) }
                }
        }
    }

    private func requestPushAuthorizationIfPaired() {
        guard !didRequestPushAuthorization,
              appState.pairedDevices.contains(where: { !$0.revoked }),
              let pushManager else { return }
        didRequestPushAuthorization = true
        Task { await pushManager.requestAuthorizationAndRegister() }
    }

    init() {
#if canImport(UIKit)
        UIApplicationBridgeLive.install()
#endif
    }

    private static func mapPhase(_ phase: ScenePhase) -> AppScenePhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}
