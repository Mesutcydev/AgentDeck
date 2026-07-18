//
//  SparkleUpdateController.swift
//  Companion — AgentDeck
//
//  §7 / §20.3 Sparkle 2 update checks. The shipped feed URL lives in
//  Info.plist (SUFeedURL); SPARKLE_FEED_URL overrides it for development.
//  https only — a cleartext appcast is never used. Updates stay
//  unconfigured until a human adds a real appcast + SUPublicEDKey
//  (NEEDS-HUMAN #2, #6).
//

import Foundation
import Shared

#if canImport(Sparkle)
import Sparkle

/// Supplies the resolved feed URL to the updater (Sparkle's supported
/// dynamic path: `setFeedURL:` is deprecated and `feedURL` is readonly).
/// The updater references its delegate weakly; the controller retains
/// this provider for the updater's lifetime.
private final class SparkleFeedURLProvider: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        SparkleConfiguration.feedURL?.absoluteString
    }
}

@MainActor
final class SparkleUpdateController: NSObject {
    private let updaterController: SPUStandardUpdaterController
    private let feedProvider = SparkleFeedURLProvider()

    override init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: feedProvider,
            userDriverDelegate: nil
        )
        super.init()
        SparkleVersionTracker.recordCurrentVersion()
        guard let feedURL = SparkleConfiguration.feedURL else {
            Log.logger(.session).info("updates unconfigured: no https SUFeedURL in Info.plist — manual updates only (SUPublicEDKey + appcast signing key required, NEEDS-HUMAN)")
            return
        }
        do {
            try updaterController.updater.start()
            Log.logger(.session).info("Sparkle updater started with feed \(feedURL.absoluteString, privacy: .public)")
        } catch {
            Log.logger(.session).error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var isConfigured: Bool { SparkleConfiguration.feedURL != nil }
}
#else
@MainActor
final class SparkleUpdateController: NSObject {
    override init() {
        super.init()
        SparkleVersionTracker.recordCurrentVersion()
        Log.logger(.session).info("updates unconfigured: Sparkle not linked — manual updates only")
    }

    func checkForUpdates() {
        Log.logger(.session).info("updates unconfigured: Sparkle not linked — manual updates only")
    }

    var isConfigured: Bool { false }
}
#endif

enum SparkleConfiguration {
    /// Feed URL resolution: the development override (SPARKLE_FEED_URL)
    /// wins; otherwise the shipped Info.plist SUFeedURL. Non-https values
    /// are rejected — a cleartext appcast would break §20.3 signature
    /// verification expectations.
    static var feedURL: URL? {
        if let raw = ProcessInfo.processInfo.environment["SPARKLE_FEED_URL"] {
            guard let url = httpsURL(raw) else {
                Log.logger(.session).error("SPARKLE_FEED_URL ignored: not a valid https URL")
                return nil
            }
            return url
        }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !raw.isEmpty else {
            return nil
        }
        guard let url = httpsURL(raw) else {
            Log.logger(.session).error("Info.plist SUFeedURL ignored: not a valid https URL")
            return nil
        }
        return url
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }
}

/// Records the running version so a later update can answer "what did we
/// update from?" during diagnostics and rollback decisions.
enum SparkleVersionTracker {
    enum DefaultsKey {
        static let currentVersion = "sparkle.currentVersion"
        static let previousVersion = "sparkle.previousVersion"
    }

    static func recordCurrentVersion(defaults: UserDefaults = .standard) {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return
        }
        if let recorded = defaults.string(forKey: DefaultsKey.currentVersion),
           recorded != version {
            defaults.set(recorded, forKey: DefaultsKey.previousVersion)
        }
        defaults.set(version, forKey: DefaultsKey.currentVersion)
    }
}
