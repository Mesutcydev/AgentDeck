//
//  PairingQRPayload.swift
//  Shared — AgentDeck
//
//  §13.2 QR payload — NORMATIVE field set, exactly:
//  { v, deviceID, publicKeyFingerprint, endpoint, nonce, protocolVersion }
//  No reusable secrets, nothing else. Extra or missing keys are a hard
//  decode error. The nonce is ≥128-bit random, single-use (server-side
//  consumption in PairingOfferManager).
//

import Foundation

/// A network endpoint as "host:port" (Bonjour name, DNS name, or IP).
public struct PeerEndpoint: Sendable, Hashable, CustomStringConvertible {
    public static let defaultPort: UInt16 = 47_777

    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = PeerEndpoint.defaultPort) {
        self.host = host
        self.port = port
    }

    public init?(_ text: String) {
        guard let separator = text.lastIndex(of: ":") else { return nil }
        let host = String(text[text.startIndex..<separator])
        guard !host.isEmpty,
              let port = UInt16(text[text.index(after: separator)...]) else {
            return nil
        }
        self.init(host: host, port: port)
    }

    public var description: String { "\(host):\(port)" }
}

/// The §13.2 QR payload. Decoding rejects any deviation from the exact
/// six-field set — a stricter contract than ordinary payloads.
public struct PairingQRPayload: Sendable, Equatable {
    public static let version: Int64 = 1
    /// §13.2: ≥128-bit single-use nonce.
    public static let nonceLength = 16

    public let deviceID: DeviceID
    /// SHA-256 hex of the Mac's identity public key (§13.1/§13.4 binding).
    public let publicKeyFingerprint: String
    public let endpoint: PeerEndpoint
    public let nonce: Data
    public let protocolVersion: Int64

    public init(
        deviceID: DeviceID,
        publicKeyFingerprint: String,
        endpoint: PeerEndpoint,
        nonce: Data,
        protocolVersion: Int64 = PairingQRPayload.version
    ) {
        self.deviceID = deviceID
        self.publicKeyFingerprint = publicKeyFingerprint
        self.endpoint = endpoint
        self.nonce = nonce
        self.protocolVersion = protocolVersion
    }
}

public enum PairingQRPayloadError: Error, Equatable {
    case unexpectedField(String)
    case unsupportedVersion(Int64)
    case invalidNonceLength(Int)
    case invalidFingerprint
    case decodingFailed(String)
}

extension PairingQRPayload {
    enum Field {
        static let v = "v"
        static let deviceID = "deviceID"
        static let publicKeyFingerprint = "publicKeyFingerprint"
        static let endpoint = "endpoint"
        static let nonce = "nonce"
        static let protocolVersion = "protocolVersion"
    }

    static let exactFieldSet: Set<String> = [
        Field.v, Field.deviceID, Field.publicKeyFingerprint,
        Field.endpoint, Field.nonce, Field.protocolVersion
    ]

    /// The QR string: canonical JSON of exactly the six fields.
    public func encoded() throws -> String {
        guard nonce.count == PairingQRPayload.nonceLength else {
            throw PairingQRPayloadError.invalidNonceLength(nonce.count)
        }
        let value: JSONValue = .object([
            (Field.v, .int(PairingQRPayload.version)),
            (Field.deviceID, deviceID.toJSONValue()),
            (Field.publicKeyFingerprint, .string(publicKeyFingerprint)),
            (Field.endpoint, .string(endpoint.description)),
            (Field.nonce, .string(nonce.base64EncodedString())),
            (Field.protocolVersion, .int(protocolVersion))
        ])
        return value.canonicalString()
    }

    public static func decode(_ text: String) throws -> PairingQRPayload {
        let parsed = try JSONParser.parse(text)
        guard let object = parsed.objectValue else {
            throw PairingQRPayloadError.decodingFailed("not an object")
        }
        for key in object.keys where !exactFieldSet.contains(key) {
            throw PairingQRPayloadError.unexpectedField(key)
        }
        let version = try parsed.intField(Field.v)
        guard version == PairingQRPayload.version else {
            throw PairingQRPayloadError.unsupportedVersion(version)
        }
        guard let deviceID = DeviceID(try parsed.stringField(Field.deviceID)) else {
            throw PairingQRPayloadError.decodingFailed("bad deviceID")
        }
        let fingerprint = try parsed.stringField(Field.publicKeyFingerprint)
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw PairingQRPayloadError.invalidFingerprint
        }
        guard let endpoint = PeerEndpoint(try parsed.stringField(Field.endpoint)) else {
            throw PairingQRPayloadError.decodingFailed("bad endpoint")
        }
        guard let nonce = Data(base64Encoded: try parsed.stringField(Field.nonce)),
              nonce.count == PairingQRPayload.nonceLength else {
            throw PairingQRPayloadError.decodingFailed("bad nonce")
        }
        return PairingQRPayload(
            deviceID: deviceID,
            publicKeyFingerprint: fingerprint,
            endpoint: endpoint,
            nonce: nonce,
            protocolVersion: try parsed.intField(Field.protocolVersion)
        )
    }
}
