//
//  AppStateTests.swift
//  CompanionTests — AgentDeck
//
//  AppState behavior with injected fakes: pause persistence (§12.6),
//  one-time onboarding flag (§12.1), login-item toggling (§12.2), live
//  menu counts from the §12.5 store, diagnostics report assembly.
//

import Foundation
import Shared
import Testing
@testable import Companion

/// Test double for SMAppService — no system side effects.
final class FakeLoginItemManager: LoginItemManaging, @unchecked Sendable {
    // Only touched from @MainActor tests.
    var status: LoginItemStatus = .notRegistered
    var registerCalls = 0
    var unregisterCalls = 0
    var error: (any Error)?

    func register() throws {
        registerCalls += 1
        if let error { throw error }
        status = .enabled
    }

    func unregister() async throws {
        unregisterCalls += 1
        if let error { throw error }
        status = .notRegistered
    }
}

struct FakeError: Error, Equatable {}

@MainActor
@Suite("companion AppState")
struct AppStateTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "com.agentdeck.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeState(
        defaults: UserDefaults? = nil,
        loginItemManager: FakeLoginItemManager = FakeLoginItemManager(),
        repository: (any SessionRepository)? = nil
    ) throws -> AppState {
        AppState(
            defaults: try defaults ?? makeDefaults(),
            loginItemManager: loginItemManager,
            repository: repository,
            recorder: DiagnosticsRecorder()
        )
    }

    @Test("Pause Remote Access persists and blocks the connection seam (§12.6)")
    func pausePersists() async throws {
        let defaults = try makeDefaults()
        let state = try makeState(defaults: defaults)
        #expect(state.remoteAccessPaused == false)
        #expect(state.isAcceptingConnections == true)

        await state.setPaused(true)
        #expect(state.remoteAccessPaused == true)
        #expect(state.isAcceptingConnections == false)

        // A fresh AppState over the same defaults sees the persisted pause.
        let reloaded = try makeState(defaults: defaults)
        #expect(reloaded.remoteAccessPaused == true)
        #expect(reloaded.isAcceptingConnections == false)
    }

    @Test("Prevent idle sleep preference persists")
    func preventIdleSleepPersists() async throws {
        let defaults = try makeDefaults()
        let state = try makeState(defaults: defaults)
        #expect(state.preventIdleSleep == false)

        await state.setPreventIdleSleep(true)
        #expect(state.preventIdleSleep == true)

        let reloaded = try makeState(defaults: defaults)
        #expect(reloaded.preventIdleSleep == true)
    }

    @Test("onboarding completes once and the flag persists (§12.1)")
    func onboardingOnce() async throws {
        let defaults = try makeDefaults()
        let state = try makeState(defaults: defaults)
        #expect(state.onboardingCompleted == false)
        await state.completeOnboarding()
        #expect(state.onboardingCompleted == true)
        let reloaded = try makeState(defaults: defaults)
        #expect(reloaded.onboardingCompleted == true)
    }

    @Test("login item toggle registers/unregisters through the manager (§12.2)")
    func loginItemToggle() async throws {
        let fake = FakeLoginItemManager()
        let state = try makeState(loginItemManager: fake)
        #expect(state.loginItemStatus == .notRegistered)

        await state.setLoginItemEnabled(true)
        #expect(fake.registerCalls == 1)
        #expect(state.loginItemStatus == .enabled)

        await state.setLoginItemEnabled(false)
        #expect(fake.unregisterCalls == 1)
        #expect(state.loginItemStatus == .notRegistered)
    }

    @Test("a failing login-item update surfaces status and records diagnostics")
    func loginItemFailure() async throws {
        let fake = FakeLoginItemManager()
        fake.error = FakeError()
        let state = try makeState(loginItemManager: fake)

        await state.setLoginItemEnabled(true)
        #expect(fake.registerCalls == 1)
        #expect(state.loginItemStatus == .notRegistered, "status reflects the real manager after failure")

        let entries = await state.recorder.recentEntries()
        #expect(entries.contains { $0.level == .error && $0.message.contains("login item update failed") })
    }

    @Test("menu counts come from the session store (§12.6)")
    func menuCounts() async throws {
        let store = try SQLiteSessionStore.inMemory()
        let state = try makeState(repository: store)
        await state.refreshStatus()
        #expect(state.activeSessionCount == 0)
        #expect(state.pendingApprovalCount == 0)
        #expect(state.pairedDeviceCount == 0)

        let agent = try #require(AgentIdentifier("com.example.adapter"))
        try await store.insertSession(SessionRecord(
            id: .random(), agent: agent, state: .thinking, createdAt: 1, updatedAt: 1
        ))
        try await store.insertSession(SessionRecord(
            id: .random(), agent: agent, state: .completed, createdAt: 2, updatedAt: 2, endedAt: 2
        ))
        let session = SessionRecord(id: .random(), agent: agent, state: .waitingForApproval, createdAt: 3, updatedAt: 3)
        try await store.insertSession(session)
        let confidence = try #require(ApprovalEligibleConfidence(.native))
        try await store.insertApproval(ApprovalRecord(request: ApprovalRequest(
            id: .random(), agent: agent, projectID: .random(), sessionID: session.id,
            tool: "shell", exactAction: "make", explanation: "build",
            workingDirectory: "/tmp", risk: .low, reversibility: .reversible,
            originalProviderPayload: .object([:]), confidence: confidence, createdAt: 4
        )))
        try await store.insertDevice(DeviceRecord(id: .random(), displayName: "iPhone", pairedAt: 1))
        try await store.insertDevice(DeviceRecord(id: .random(), displayName: "Old iPad", pairedAt: 1, revoked: true))

        await state.refreshStatus()
        #expect(state.activeSessionCount == 2, "thinking + waitingForApproval are active; completed is not")
        #expect(state.pendingApprovalCount == 1)
        #expect(state.pairedDeviceCount == 1, "revoked devices do not count")
    }

    @Test("diagnostics report carries status fields and redacted entries")
    func diagnosticsReport() async throws {
        let state = try makeState()
        await state.setPaused(true)
        await state.recorder.record(
            category: .session, level: .info,
            message: "launched with password=hunter2"
        )
        let report = await state.buildDiagnosticsReport()
        let canonical = String(decoding: report.canonicalBytes(), as: UTF8.self)
        #expect(canonical.contains("\"remoteAccessPaused\":true"))
        #expect(canonical.contains("\"pairedDevices\":0"))
        #expect(canonical.contains("\"loginItem\":\"notRegistered\""))
        #expect(!canonical.contains("hunter2"))
    }
}
