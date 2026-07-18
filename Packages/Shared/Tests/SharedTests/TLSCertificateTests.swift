//
//  TLSCertificateTests.swift
//  SharedTests — AgentDeck
//
//  TLS credential tests: P-256 cert generation, SecIdentity round-trip
//  through the Keychain, public-key-hash pinning values.
//

import CryptoKit
import Foundation
import Security
import Testing
@testable import Shared

@Suite("TLS identity (P-256)", .serialized)
struct TLSCertificateTests {
    private func makeStore() -> TLSIdentityStore {
        TLSIdentityStore(service: "com.agentdeck.tests.tls.\(UUID().uuidString)")
    }

    @Test("generated ECDSA cert parses and SecIdentity resolves from the Keychain")
    func identityRoundTrip() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            defer { try? store.delete() }
            let identity = try store.loadOrCreate()
            #expect(identity.publicKey.count == 65, "X9.63 P-256 public key")
            #expect(identity.publicKeyHash.count == 64)

            let loaded = try #require(try store.load())
            #expect(loaded.publicKeyHash == identity.publicKeyHash)
        }
    }

    @Test("rotation replaces the TLS key")
    func rotation() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            defer { try? store.delete() }
            let first = try store.loadOrCreate()
            let second = try store.generateAndStore()
            #expect(first.publicKeyHash != second.publicKeyHash)
        }
    }

    @Test("delete removes the identity")
    func deletion() async throws {
        try await KeychainTestLock.withLock {
            let store = makeStore()
            _ = try store.loadOrCreate()
            try store.delete()
            try store.delete()
            #expect(try store.load() == nil)
        }
    }
}
