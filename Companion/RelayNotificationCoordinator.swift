//
//  RelayNotificationCoordinator.swift
//  Companion — AgentDeck
//
//  §14.3 Mac companion relay dispatch for background iOS alerts.
//

import CryptoKit
import Foundation
import Security
import Shared

@MainActor
final class RelayNotificationCoordinator {
    struct Configuration {
        var relayBaseURL: URL
        var signingPrivateKey: Curve25519.Signing.PrivateKey
    }

    private let repository: any SessionRepository
    private let recorder: DiagnosticsRecorder?
    private var configuration: Configuration?
    private var client: RelayHTTPClient?

    init(repository: any SessionRepository, recorder: DiagnosticsRecorder? = nil) {
        self.repository = repository
        self.recorder = recorder
    }

    /// Pass nil to disable relay dispatch (no relay URL configured).
    func configure(_ configuration: Configuration?) {
        self.configuration = configuration
        self.client = configuration.map {
            RelayHTTPClient(configuration: .init(
                baseURL: $0.relayBaseURL,
                signingPrivateKey: $0.signingPrivateKey
            ))
        }
    }

    func dispatch(event: AgentEvent) async {
        guard let client else { return }
        do {
            let devices = try await repository.listDevices()
            guard let device = devices.first(where: { !$0.revoked }),
                  let token = device.pushDestinationToken else {
                return
            }
            let projectAlias = await projectAlias(for: event.sessionID)
            guard let request = RelayNotificationBuilder.build(
                from: event,
                destinationToken: token,
                projectAlias: projectAlias
            ) else {
                return
            }
            try await client.send(request)
            Log.logger(.session).info("relay notification sent: \(request.eventType.rawValue, privacy: .public)")
        } catch {
            Log.logger(.session).error("relay dispatch failed: \(error.localizedDescription, privacy: .public)")
            await recorder?.record(
                category: .session, level: .error,
                message: "relay dispatch failed: \(error.localizedDescription)"
            )
        }
    }

    private func projectAlias(for sessionID: SessionID) async -> String? {
        guard
            let session = try? await repository.session(id: sessionID),
            let projectID = session.projectID,
            let project = try? await repository.project(id: projectID)
        else {
            return nil
        }
        return project.displayName
    }
}

/// Keychain-backed storage for the §14.3 relay signing key: a
/// generic-password item, ThisDeviceOnly so the key never syncs off the
/// Mac (mirrors `KeychainIdentityStore` in Shared).
struct RelaySigningKeyStore: Sendable {
    static let legacyDefaultsKey = "agentdeck.relaySigningKey"

    private let service = "\(ProductNaming.logSubsystem).relay-signing"
    private let account = "relay-signing-key"

    enum StoreError: Error, Equatable {
        case keychainCorrupt
        case keychainError(OSStatus)
    }

    /// Loads the persisted key, or generates, stores, and returns a fresh
    /// one on first use.
    func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let stored = try load() {
            return stored
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        try store(privateKey.rawRepresentation)
        return privateKey
    }

    func load() throws -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = result as? Data,
                  let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
                throw StoreError.keychainCorrupt
            }
            return privateKey
        default:
            throw StoreError.keychainError(status)
        }
    }

    func store(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.keychainError(status)
        }
    }
}

extension RelayNotificationCoordinator {
    /// Loads (or creates) the relay signing key from the Keychain. A
    /// one-time migration moves the Phase 10 UserDefaults plaintext copy
    /// into the Keychain and removes it from defaults.
    static func loadOrCreateSigningKey(
        store: RelaySigningKeyStore = RelaySigningKeyStore(),
        defaults: UserDefaults = .standard
    ) throws -> Curve25519.Signing.PrivateKey {
        if let legacy = defaults.data(forKey: RelaySigningKeyStore.legacyDefaultsKey) {
            defaults.removeObject(forKey: RelaySigningKeyStore.legacyDefaultsKey)
            // Skip the migration when a Keychain key already exists or the
            // legacy value is not a valid key (a fresh one is generated).
            if (try? store.load()) == nil,
               (try? Curve25519.Signing.PrivateKey(rawRepresentation: legacy)) != nil {
                try store.store(legacy)
                Log.logger(.security).info("migrated relay signing key from UserDefaults to Keychain")
            }
        }
        return try store.loadOrCreate()
    }
}
