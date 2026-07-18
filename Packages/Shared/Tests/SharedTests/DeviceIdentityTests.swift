//
//  DeviceIdentityTests.swift
//  SharedTests — AgentDeck
//
//  §13.1 device identity: generation, Keychain round-trip, rotation,
//  fingerprint stability, no-hardware-derivation property.
//

import CryptoKit
import Foundation
import Testing
@testable import Shared

@Suite("§13.1 device identity", .serialized)
struct DeviceIdentityTests {
    private func makeStore() -> KeychainIdentityStore {
        KeychainIdentityStore(service: "com.agentdeck.tests.identity.\(UUID().uuidString)")
    }

    @Test("loadOrCreate generates once, then returns the same identity")
    func loadOrCreateStable() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            defer { try? store.delete() }
            let first = try store.loadOrCreate()
            let second = try store.loadOrCreate()
            #expect(first == second)
        }
    }

    @Test("private key round-trips through the Keychain and matches the public key")
    func privateKeyRoundTrip() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            defer { try? store.delete() }
            let identity = try store.loadOrCreate()
            let privateKey = try store.privateKey()
            #expect(privateKey.publicKey.rawRepresentation == identity.publicKey.rawRepresentation)
            let signature = try privateKey.signature(for: Data("agentdeck".utf8))
            #expect(identity.publicKey.isValidSignature(signature, for: Data("agentdeck".utf8)))
        }
    }

    @Test("rotation produces a fresh device ID and key")
    func rotation() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            defer { try? store.delete() }
            let original = try store.loadOrCreate()
            let rotated = try store.generateAndStore()
            #expect(rotated.deviceID != original.deviceID)
            #expect(rotated.publicKey.rawRepresentation != original.publicKey.rawRepresentation)
            #expect(try store.loadOrCreate() == rotated)
        }
    }

    @Test("fingerprint is SHA-256 hex of the raw public key and stable")
    func fingerprint() throws {
        let key = Curve25519.Signing.PrivateKey()
        let expected = SHA256.hash(data: key.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }.joined()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: key.publicKey)
        #expect(identity.fingerprint == expected)
        #expect(identity.fingerprint.count == 64)
        #expect(identity.shortFingerprint == String(expected.prefix(16)))
    }

    @Test("device IDs are random — not hardware-derived")
    func randomIDs() throws {
        let ids = (0..<50).map { _ in DeviceID.random() }
        #expect(Set(ids).count == 50, "IDs must be unique random v4 UUIDs")
        for id in ids {
            let text = id.wireString
            let versionIndex = text.index(text.startIndex, offsetBy: 14)
            #expect(text[versionIndex] == "4")
        }
    }

    @Test("delete removes the stored identity")
    func deleteIdentity() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            _ = try store.loadOrCreate()
            try store.delete()
            try store.delete() // idempotent — errSecItemNotFound is OK
            #expect(try store.load() == nil)
        }
    }
}
