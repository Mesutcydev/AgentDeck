//
//  DeviceIdentity.swift
//  Shared — AgentDeck
//
//  §13.1 device identity: a CryptoKit Curve25519 signing key pair
//  generated per installation; the private key lives in the Keychain;
//  device IDs are random v4 UUIDs — never derived from hardware
//  identifiers. Supports store / load / rotate. The same code runs on
//  macOS (companion) and iOS (app).
//

import CryptoKit
import Foundation
import Security

/// A device's long-term identity: random device ID + Ed25519 signing key.
public struct DeviceIdentity: Sendable, Equatable {
    public let deviceID: DeviceID
    public let publicKey: Curve25519.Signing.PublicKey

    public init(deviceID: DeviceID, publicKey: Curve25519.Signing.PublicKey) {
        self.deviceID = deviceID
        self.publicKey = publicKey
    }

    public static func == (lhs: DeviceIdentity, rhs: DeviceIdentity) -> Bool {
        lhs.deviceID == rhs.deviceID
            && lhs.publicKey.rawRepresentation == rhs.publicKey.rawRepresentation
    }

    /// §13.2 fingerprint: SHA-256 of the raw public key, lowercase hex.
    /// This is what the QR payload carries and what endpoint binding pins.
    public var fingerprint: String {
        DeviceIdentity.fingerprint(of: publicKey)
    }

    public static func fingerprint(of publicKey: Curve25519.Signing.PublicKey) -> String {
        SHA256.hash(data: publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Short form for human comparison screens.
    public var shortFingerprint: String { String(fingerprint.prefix(16)) }
}

/// Keychain-backed identity storage (§13.1: private keys in Keychain).
/// Stored as a generic-password item holding `deviceID || privateKey`.
public struct KeychainIdentityStore: Sendable {
    private let service: String

    public init(service: String = "\(ProductNaming.logSubsystem).identity") {
        self.service = service
    }

    private let account = "device-identity"

    /// Loads the persisted identity, or generates, stores, and returns a
    /// fresh one on first launch.
    public func loadOrCreate() throws -> DeviceIdentity {
        if let stored = try load() {
            return stored.identity
        }
        let identity = try generateAndStore()
        return identity
    }

    /// Loads the identity together with the private signing key (nil on
    /// first launch). The private key leaves the store only as a CryptoKit
    /// object in process memory.
    public func load() throws -> StoredIdentity? {
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
            guard let data = result as? Data else {
                throw DeviceIdentityError.keychainCorrupt
            }
            return try Self.decode(data)
        default:
            throw DeviceIdentityError.keychainError(status)
        }
    }

    /// Generates a NEW identity (fresh device ID + fresh key) and persists
    /// it — used on first launch and on rotation. Rotation invalidates the
    /// previous identity: peers must re-pair (§13.1 rotatable credentials;
    /// revocation is the companion feature).
    @discardableResult
    public func generateAndStore() throws -> DeviceIdentity {
        let privateKey = Curve25519.Signing.PrivateKey()
        let identity = DeviceIdentity(deviceID: .random(), publicKey: privateKey.publicKey)
        try store(Self.encode(identity: identity, privateKey: privateKey))
        return identity
    }

    /// The private key for signing (frames, attestations). Never leaves
    /// the device; never logged (Constitution #8).
    public func privateKey() throws -> Curve25519.Signing.PrivateKey {
        guard let stored = try load() else {
            throw DeviceIdentityError.noIdentity
        }
        return stored.privateKey
    }

    /// Deletes the stored identity (full local-data wipe path, §21).
    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceIdentityError.keychainError(status)
        }
    }

    // MARK: - Encoding

    public struct StoredIdentity: Sendable {
        let identity: DeviceIdentity
        let privateKey: Curve25519.Signing.PrivateKey
    }

    private static func encode(
        identity: DeviceIdentity,
        privateKey: Curve25519.Signing.PrivateKey
    ) -> Data {
        var data = Data()
        var uuidTuple = identity.deviceID.uuid.uuid
        data.append(withUnsafeBytes(of: &uuidTuple) { Data($0) })
        data.append(privateKey.rawRepresentation)
        return data
    }

    private static func decode(_ data: Data) throws -> StoredIdentity {
        guard data.count == 48 else {
            throw DeviceIdentityError.keychainCorrupt
        }
        let uuid = NSUUID(uuidBytes: [UInt8](data.prefix(16))) as UUID
        guard let privateKey = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: data.suffix(32)
        ) else {
            throw DeviceIdentityError.keychainCorrupt
        }
        return StoredIdentity(
            identity: DeviceIdentity(deviceID: DeviceID(uuid: uuid), publicKey: privateKey.publicKey),
            privateKey: privateKey
        )
    }

    private func store(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        // ThisDeviceOnly: identity never syncs off the device (§13.1).
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityError.keychainError(status)
        }
    }
}

public enum DeviceIdentityError: Error, Equatable {
    case noIdentity
    case keychainCorrupt
    case keychainError(OSStatus)
}
