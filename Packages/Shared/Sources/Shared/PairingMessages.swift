//
//  PairingMessages.swift
//  Shared — AgentDeck
//
//  §13.2 pairing handshake payloads and the §9 session.resume payload.
//  Every message is versioned (payloadV). Frames carrying them are signed
//  by the sender's identity key (§9); during pairing, each side learns the
//  peer's key FROM these payloads and binds it via fingerprint, phrase,
//  and mutual confirmation before persisting anything.
//

import CryptoKit
import Foundation

/// §13.2 granted capabilities (persisted per peer after pairing).
public enum PeerCapability: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case sessions
    case approvals
    case clipboard
    case attachments
}

// MARK: - pairing.hello (client → server)

/// Client introduction: proves knowledge of the QR nonce and presents the
/// client's identity key for the server to pin after confirmation.
public struct PairingHello: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    /// The nonce from the scanned QR payload (freshness + single-use).
    public let nonce: Data
    public let clientDeviceID: DeviceID
    /// 32-byte Ed25519 identity public key.
    public let clientPublicKey: Data
    public let clientDisplayName: String
    public let protocolVersion: Int64

    public init(
        nonce: Data,
        clientDeviceID: DeviceID,
        clientPublicKey: Data,
        clientDisplayName: String,
        protocolVersion: Int64
    ) {
        self.nonce = nonce
        self.clientDeviceID = clientDeviceID
        self.clientPublicKey = clientPublicKey
        self.clientDisplayName = clientDisplayName
        self.protocolVersion = protocolVersion
    }
}

// MARK: - pairing.accept (server → client)

public struct PairingAccept: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let serverDeviceID: DeviceID
    public let serverPublicKey: Data
    public let serverDisplayName: String
    public let protocolVersion: Int64
    /// 32-byte random code feeding the verification phrase (§13.2).
    public let verificationCode: Data
    /// SHA-256 hex of the TLS public key this server is presenting
    /// (§13.4 endpoint binding, ADR-0008).
    public let tlsPublicKeyHash: String
    /// Identity-key signature binding the TLS key to this device
    /// (see `PairingAttestation`).
    public let attestation: Data

    public init(
        serverDeviceID: DeviceID,
        serverPublicKey: Data,
        serverDisplayName: String,
        protocolVersion: Int64,
        verificationCode: Data,
        tlsPublicKeyHash: String,
        attestation: Data
    ) {
        self.serverDeviceID = serverDeviceID
        self.serverPublicKey = serverPublicKey
        self.serverDisplayName = serverDisplayName
        self.protocolVersion = protocolVersion
        self.verificationCode = verificationCode
        self.tlsPublicKeyHash = tlsPublicKeyHash
        self.attestation = attestation
    }
}

// MARK: - pairing.reject (server → client)

public enum PairingRejectReason: String, Sendable, JSONValueConvertible {
    case unknownNonce
    case nonceExpired
    case nonceAlreadyUsed
    case protocolMismatch
    case deviceLimitReached
    case rateLimited
    case revoked
    case cancelled
}

public struct PairingReject: Sendable, Equatable {
    public static let payloadV: Int64 = 1
    public let reason: PairingRejectReason

    public init(reason: PairingRejectReason) {
        self.reason = reason
    }
}

// MARK: - pairing.confirm (both directions)

/// Human confirmation of the verification phrase on one side; pairing
/// completes only when BOTH sides have confirmed (§13.2 mutual
/// confirmation).
public struct PairingConfirm: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    public let deviceID: DeviceID
    public let confirmed: Bool

    public init(deviceID: DeviceID, confirmed: Bool) {
        self.deviceID = deviceID
        self.confirmed = confirmed
    }
}

// MARK: - pairing.complete (server → client)

public struct PairingComplete: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    /// The negotiated protocol version (§13.2 version negotiation).
    public let protocolVersion: Int64
    public let grantedCapabilities: [PeerCapability]
    /// Signed server-preferred reconnect endpoint. Optional for wire
    /// compatibility with earlier companions.
    public let reconnectEndpoint: PeerEndpoint?

    public init(
        protocolVersion: Int64,
        grantedCapabilities: [PeerCapability],
        reconnectEndpoint: PeerEndpoint? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.grantedCapabilities = grantedCapabilities
        self.reconnectEndpoint = reconnectEndpoint
    }
}

// MARK: - session.resume payload (§9, §14.1)

/// Client → server on reconnect: replay events after `lastCursor`.
public struct SessionResumeRequest: Sendable, Equatable {
    public static let payloadV: Int64 = 1

    /// Nil means "from the beginning".
    public let lastCursor: EventCursor?

    public init(lastCursor: EventCursor?) {
        self.lastCursor = lastCursor
    }
}

// MARK: - JSONValue conformances

extension PairingHello: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PairingHello.payloadV)
        guard let nonce = Data(base64Encoded: try jsonValue.stringField("nonce")),
              let publicKey = Data(base64Encoded: try jsonValue.stringField("clientPublicKey")) else {
            throw JSONValueDecodingError.invalidValue(field: "pairing.hello", reason: "bad base64")
        }
        self.init(
            nonce: nonce,
            clientDeviceID: try jsonValue.nestedField("clientDeviceID", as: DeviceID.self),
            clientPublicKey: publicKey,
            clientDisplayName: try jsonValue.stringField("clientDisplayName"),
            protocolVersion: try jsonValue.intField("protocolVersion")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(PairingHello.payloadV)),
            ("nonce", .string(nonce.base64EncodedString())),
            ("clientDeviceID", clientDeviceID.toJSONValue()),
            ("clientPublicKey", .string(clientPublicKey.base64EncodedString())),
            ("clientDisplayName", .string(clientDisplayName)),
            ("protocolVersion", .int(protocolVersion))
        ])
    }
}

extension PairingAccept: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PairingAccept.payloadV)
        guard let publicKey = Data(base64Encoded: try jsonValue.stringField("serverPublicKey")),
              let code = Data(base64Encoded: try jsonValue.stringField("verificationCode")),
              let attestation = Data(base64Encoded: try jsonValue.stringField("attestation")) else {
            throw JSONValueDecodingError.invalidValue(field: "pairing.accept", reason: "bad base64")
        }
        self.init(
            serverDeviceID: try jsonValue.nestedField("serverDeviceID", as: DeviceID.self),
            serverPublicKey: publicKey,
            serverDisplayName: try jsonValue.stringField("serverDisplayName"),
            protocolVersion: try jsonValue.intField("protocolVersion"),
            verificationCode: code,
            tlsPublicKeyHash: try jsonValue.stringField("tlsPublicKeyHash"),
            attestation: attestation
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(PairingAccept.payloadV)),
            ("serverDeviceID", serverDeviceID.toJSONValue()),
            ("serverPublicKey", .string(serverPublicKey.base64EncodedString())),
            ("serverDisplayName", .string(serverDisplayName)),
            ("protocolVersion", .int(protocolVersion)),
            ("verificationCode", .string(verificationCode.base64EncodedString())),
            ("tlsPublicKeyHash", .string(tlsPublicKeyHash)),
            ("attestation", .string(attestation.base64EncodedString()))
        ])
    }
}

extension PairingReject: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PairingReject.payloadV)
        self.init(reason: try jsonValue.nestedField("reason", as: PairingRejectReason.self))
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(PairingReject.payloadV)),
            ("reason", reason.toJSONValue())
        ])
    }
}

extension PairingConfirm: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PairingConfirm.payloadV)
        self.init(
            deviceID: try jsonValue.nestedField("deviceID", as: DeviceID.self),
            confirmed: try jsonValue.boolField("confirmed")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("payloadV", .int(PairingConfirm.payloadV)),
            ("deviceID", deviceID.toJSONValue()),
            ("confirmed", .bool(confirmed))
        ])
    }
}

extension PairingComplete: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: PairingComplete.payloadV)
        self.init(
            protocolVersion: try jsonValue.intField("protocolVersion"),
            grantedCapabilities: try jsonValue.nestedArrayField("grantedCapabilities", as: PeerCapability.self),
            reconnectEndpoint: try jsonValue.optionalStringField("reconnectEndpoint").flatMap(PeerEndpoint.init)
        )
    }

    public func toJSONValue() -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("payloadV", .int(PairingComplete.payloadV)),
            ("protocolVersion", .int(protocolVersion)),
            ("grantedCapabilities", .array(grantedCapabilities.map { $0.toJSONValue() }))
        ]
        if let reconnectEndpoint {
            pairs.append(("reconnectEndpoint", .string(reconnectEndpoint.description)))
        }
        return .object(pairs)
    }
}

extension SessionResumeRequest: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        try requirePayloadV(jsonValue, supported: SessionResumeRequest.payloadV)
        self.init(
            lastCursor: try jsonValue.optionalNestedField("lastCursor", as: EventCursor.self)
        )
    }

    public func toJSONValue() throws -> JSONValue {
        var pairs: [(String, JSONValue)] = [("payloadV", .int(SessionResumeRequest.payloadV))]
        if let lastCursor {
            pairs.append(("lastCursor", try lastCursor.toJSONValue()))
        }
        return .object(pairs)
    }
}

// MARK: - §13.4 endpoint-binding attestation (ADR-0008)

/// The identity key's endorsement of the TLS key: Ed25519 signature over
/// the canonical encoding of {serverDeviceID, tlsPublicKeyHash, nonce}.
/// The client verifies it against the QR identity fingerprint AND the
/// TLS-captured public-key hash — the certificate's public key is thereby
/// "signed by" the identity key (SPEC v2.1 endpoint binding).
public enum PairingAttestation {
    public static func signingInput(
        serverDeviceID: DeviceID,
        tlsPublicKeyHash: String,
        nonce: Data
    ) -> Data {
        let value: JSONValue = .object([
            ("nonce", .string(nonce.base64EncodedString())),
            ("serverDeviceID", serverDeviceID.toJSONValue()),
            ("tlsPublicKeyHash", .string(tlsPublicKeyHash))
        ])
        return value.canonicalBytes()
    }

    public static func sign(
        serverDeviceID: DeviceID,
        tlsPublicKeyHash: String,
        nonce: Data,
        with privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        try privateKey.signature(
            for: signingInput(serverDeviceID: serverDeviceID, tlsPublicKeyHash: tlsPublicKeyHash, nonce: nonce)
        )
    }

    public static func verify(
        _ attestation: Data,
        serverDeviceID: DeviceID,
        tlsPublicKeyHash: String,
        nonce: Data,
        publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        publicKey.isValidSignature(
            attestation,
            for: signingInput(serverDeviceID: serverDeviceID, tlsPublicKeyHash: tlsPublicKeyHash, nonce: nonce)
        )
    }
}
