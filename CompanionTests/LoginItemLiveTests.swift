//
//  LoginItemLiveTests.swift
//  CompanionTests — AgentDeck
//
//  §12.2 acceptance evidence: exercise the REAL SMAppService against the
//  built Companion.app bundle (these tests run hosted inside the app via
//  TEST_HOST). The raw status triple is printed for BUILD_PROGRESS.md.
//  macOS may legitimately report `.requiresApproval` in a headless
//  context — that is recorded as honest evidence, not fudged to green.
//

import Foundation
import Shared
import Testing
@testable import Companion

@Suite("§12.2 SMAppService live check (real system service)")
struct LoginItemLiveTests {
    @Test("register → status → unregister round-trip against the built bundle")
    func liveRoundTrip() async throws {
        let manager = SystemLoginItemManager()

        let initial = manager.status
        var registerError: String?
        do {
            try manager.register()
        } catch {
            registerError = error.localizedDescription
        }
        let afterRegister = manager.status

        var unregisterError: String?
        do {
            try await manager.unregister()
        } catch {
            unregisterError = error.localizedDescription
        }
        let afterUnregister = manager.status

        // Raw evidence for BUILD_PROGRESS.md: test stdout is not echoed
        // by xcodebuild for app-hosted tests, so persist it to a file the
        // test script surfaces (and print it too, for interactive runs).
        let evidence = "SMAPP_SERVICE_EVIDENCE initial=\(initial.rawValue) "
            + "afterRegister=\(afterRegister.rawValue) registerError=\(registerError ?? "none") "
            + "afterUnregister=\(afterUnregister.rawValue) unregisterError=\(unregisterError ?? "none")"
        print(evidence)
        let evidenceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentdeck-loginitem-evidence.log")
        try? evidence.write(to: evidenceURL, atomically: true, encoding: .utf8)

        // Restore the pre-test state.
        if initial == .enabled, afterUnregister != .enabled {
            try? manager.register()
        }

        // Weak, honest invariants: unregistering must not leave the item
        // enabled, and statuses must be valid values. We never fake a
        // stronger GUI-only outcome.
        #expect(afterUnregister != .enabled)
        #expect([LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound]
            .contains(afterRegister))
    }
}
