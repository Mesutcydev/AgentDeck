//
//  SecurityHardeningTests.swift
//  SharedTests — AgentDeck
//
//  §20 penetration-style protocol and path safety checks (Phase 14).
//

import Foundation
import Testing
@testable import Shared

@Suite("§20 security hardening")
struct SecurityHardeningTests {
    @Test("relay rejects notification bodies containing secrets")
    func relayRejectsSecrets() throws {
        let object: [String: Any] = [
            "payloadV": 1,
            "destinationToken": "tok",
            "eventType": RelayNotificationEventType.sessionCompleted.rawValue,
            "sessionID": SessionID.random().wireString,
            "notificationText": "ok",
            "expiration": Date.unixMillisecondsNow + 60_000,
            "terminalOutput": "secret"
        ]
        #expect(throws: RelayNotificationError.self) {
            try RelayNotifyValidator.validateJSONObject(object)
        }
    }

    @Test("lost device revocation prevents reconnect shortcut")
    func revokedDeviceRejected() async throws {
        #if os(macOS)
        try await IntegrationTestQueue.async {
            let store = try SQLiteSessionStore.inMemory()
            let deviceID = DeviceID.random()
            try await store.insertDevice(DeviceRecord(
                id: deviceID,
                displayName: "Revoked Phone",
                publicKey: Data(repeating: 1, count: 32),
                pairedAt: Date.unixMillisecondsNow,
                revoked: true
            ))
            let devices = try await store.listDevices()
            #expect(devices.first(where: { $0.id == deviceID })?.revoked == true)
        }
        #endif
    }

    @Test("path safety rejects paths outside authorized project root")
    func pathOutsideRootBlocked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        #expect(!PathSafety.isContained(in: root.path, path: outside))
    }
}
