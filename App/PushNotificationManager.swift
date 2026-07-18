//
//  PushNotificationManager.swift
//  App — AgentDeck
//
//  §14.1–§14.2 APNs registration, categories, and deep-link routing.
//  Notification actions never approve anything: open routes into the app,
//  deny requires low/medium risk + device-owner authentication, stop
//  requires authentication (§15.4).
//

import Foundation
import Shared
import UserNotifications

@MainActor
final class PushNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    /// Action identifiers registered on the notification categories.
    private enum ActionID {
        static let openApproval = "open_approval"
        static let deny = "deny"
        static let stopSession = "stop_session"
    }

    private weak var appState: IOSAppState?

    init(appState: IOSAppState) {
        self.appState = appState
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { return }
            UIApplicationBridge.registerForRemoteNotifications()
        } catch {
            appState?.setError("Notification authorization failed: \(error.localizedDescription)", domain: .connection)
        }
    }

    func handleDeviceToken(_ tokenData: Data) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard let destination = PushDestinationToken(token) else { return }
        await appState?.registerPushDestinationToken(destination)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let link = NotificationDeepLink.parse(userInfo: userInfo) else { return }
        switch response.actionIdentifier {
        case ActionID.deny:
            // Deny without opening the app: IOSAppState enforces the
            // low/medium-risk gate and device-owner authentication, and
            // reads the risk from the local mirrored repository.
            await appState?.denyApprovalFromNotification(sessionID: link.sessionID)
        case ActionID.stopSession:
            await appState?.interruptSessionFromNotification(sessionID: link.sessionID)
        case ActionID.openApproval, UNNotificationDefaultActionIdentifier:
            await handleDeepLink(link)
        default:
            // Dismissal and unknown actions do nothing.
            break
        }
    }

    @MainActor
    private func handleDeepLink(_ link: NotificationDeepLink) async {
        await appState?.openNotificationDeepLink(link)
    }

    private static var categories: Set<UNNotificationCategory> {
        let openApproval = UNNotificationAction(
            identifier: ActionID.openApproval,
            title: "Open Approval",
            options: [.foreground]
        )
        // Background-capable deny; the device must be unlocked first so
        // device-owner authentication can run. Never an approve action.
        let deny = UNNotificationAction(
            identifier: ActionID.deny,
            title: "Deny",
            options: [.authenticationRequired]
        )
        let stop = UNNotificationAction(
            identifier: ActionID.stopSession,
            title: "Stop Session",
            options: [.authenticationRequired, .destructive]
        )
        return [
            UNNotificationCategory(
                identifier: RelayNotificationEventType.approvalRequired.rawValue,
                actions: [openApproval, deny],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: RelayNotificationEventType.sessionCompleted.rawValue,
                actions: [],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: RelayNotificationEventType.sessionFailed.rawValue,
                actions: [stop],
                intentIdentifiers: []
            )
        ]
    }
}

/// Keeps UIKit registration out of SwiftUI previews/tests.
enum UIApplicationBridge {
    @MainActor static var registerForRemoteNotifications: () -> Void = {}
}

#if canImport(UIKit)
import UIKit

enum UIApplicationBridgeLive {
    @MainActor static func install() {
        UIApplicationBridge.registerForRemoteNotifications = {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}
#endif
