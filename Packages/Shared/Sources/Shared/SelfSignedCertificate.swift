//
//  SelfSignedCertificate.swift
//  Shared — AgentDeck
//
//  Minimal X.509 v3 self-signed certificate construction and verification
//  for §13.4 endpoint binding: the companion's TLS certificate carries the
//  Ed25519 identity public key, self-signed by the identity key — so the
//  cert's public key EQUALS the identity key whose fingerprint was
//  exchanged in the QR payload (SPEC v2.1 endpoint binding).
//
//  This is deterministic ASN.1/DER encoding plus a small DER reader —
//  not cryptography: the only signature is CryptoKit Ed25519 over the
//  TBSCertificate bytes.
//

import CryptoKit
import Foundation

public enum CertificateError: Error, Equatable {
    case malformedDER(String)
    case invalidSignature
}

public enum SelfSignedCertificate {
    /// Builds a self-signed X.509 v3 certificate (DER) binding
    /// `commonName` to the Ed25519 `publicKey`, signed by `privateKey`.
    public static func ed25519(
        commonName: String,
        publicKey: Curve25519.Signing.PublicKey,
        signWith privateKey: Curve25519.Signing.PrivateKey,
        notBefore: Date,
        notAfter: Date,
        serial: UInt64
    ) throws -> Data {
        let algorithmID = DER.sequence(DER.oid([0x2B, 0x65, 0x70])) // 1.3.101.112 Ed25519
        let name = DER.sequence(DER.set(
            DER.sequence(DER.oid([0x55, 0x04, 0x03]) + DER.utf8String(commonName))
        ))
        let tbs = DER.sequence(
            DER.explicitTag(0, DER.integer(2)) // version v3
                + DER.integer(serial)
                + algorithmID
                + name
                + DER.sequence(DER.utcTime(notBefore) + DER.utcTime(notAfter))
                + name
                + DER.sequence(
                    algorithmID
                        + DER.bitString(publicKey.rawRepresentation)
                )
        )
        let signature = try privateKey.signature(for: tbs)
        return DER.sequence(
            tbs
                + algorithmID
                + DER.bitString(signature)
        )
    }

    /// The parsed pieces of a certificate built by `ed25519(...)`.
    public struct ParsedCertificate: Sendable {
        /// Full TLV bytes of the TBSCertificate (what the signature covers).
        public let tbsBytes: Data
        /// The enclosed Ed25519 identity public key.
        public let publicKey: Curve25519.Signing.PublicKey
        /// The self-signature over `tbsBytes`.
        public let signature: Data
    }

    /// Parses a certificate built by `ed25519(...)` and verifies its
    /// self-signature with the enclosed key. Returns the parsed parts so
    /// endpoint binding can compare `publicKey` against the pairing
    /// fingerprint. Throws on malformed DER or an invalid signature.
    public static func parseAndVerifyEd25519(der: Data) throws -> ParsedCertificate {
        var reader = DERReader(der)
        let outer = try reader.readElement()
        guard outer.tag == 0x30 else {
            throw CertificateError.malformedDER("certificate is not a SEQUENCE")
        }
        try reader.expectEnd()

        var inner = DERReader(outer.content)
        let tbs = try inner.readElement()
        guard tbs.tag == 0x30 else {
            throw CertificateError.malformedDER("tbsCertificate is not a SEQUENCE")
        }
        _ = try inner.readElement() // signatureAlgorithm
        let signatureElement = try inner.readElement()
        guard signatureElement.tag == 0x03, signatureElement.content.first == 0x00 else {
            throw CertificateError.malformedDER("signatureValue is not a BIT STRING")
        }
        let signature = signatureElement.content.dropFirst()

        // Walk the TBS to the subjectPublicKeyInfo BIT STRING.
        var tbsReader = DERReader(tbs.content)
        _ = try tbsReader.readElement() // [0] version
        _ = try tbsReader.readElement() // serialNumber
        _ = try tbsReader.readElement() // signature algorithm
        _ = try tbsReader.readElement() // issuer
        _ = try tbsReader.readElement() // validity
        _ = try tbsReader.readElement() // subject
        let spki = try tbsReader.readElement()
        guard spki.tag == 0x30 else {
            throw CertificateError.malformedDER("subjectPublicKeyInfo is not a SEQUENCE")
        }
        var spkiReader = DERReader(spki.content)
        _ = try spkiReader.readElement() // algorithm identifier
        let keyElement = try spkiReader.readElement()
        guard keyElement.tag == 0x03, keyElement.content.first == 0x00 else {
            throw CertificateError.malformedDER("subjectPublicKey is not a BIT STRING")
        }
        let keyBytes = keyElement.content.dropFirst()
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            throw CertificateError.malformedDER("subjectPublicKey is not Ed25519")
        }

        guard publicKey.isValidSignature(signature, for: tbs.fullBytes) else {
            throw CertificateError.invalidSignature
        }
        return ParsedCertificate(tbsBytes: tbs.fullBytes, publicKey: publicKey, signature: signature)
    }
}

/// Minimal DER writer for exactly the X.509 subset above.
enum DER {
    static func sequence(_ content: Data) -> Data { wrap(0x30, content) }
    static func set(_ content: Data) -> Data { wrap(0x31, content) }
    static func oid(_ encoded: [UInt8]) -> Data { wrap(0x06, Data(encoded)) }
    static func utf8String(_ string: String) -> Data { wrap(0x0C, Data(string.utf8)) }

    static func integer(_ value: UInt64) -> Data {
        var bytes = withUnsafeBytes(of: value.bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0x00, (bytes.dropFirst().first ?? 0) & 0x80 == 0 {
            bytes = bytes.dropFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 {
            bytes = Data([0x00]) + bytes
        }
        return wrap(0x02, bytes)
    }

    static func bitString(_ data: Data) -> Data {
        wrap(0x03, Data([0x00]) + data)
    }

    static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = (components.year ?? 1970) % 100
        let text = String(
            format: "%02d%02d%02d%02d%02d%02dZ",
            year, components.month ?? 1, components.day ?? 1,
            components.hour ?? 0, components.minute ?? 0, components.second ?? 0
        )
        return wrap(0x17, Data(text.utf8))
    }

    static func explicitTag(_ tag: UInt8, _ content: Data) -> Data {
        wrap(0xA0 + tag, content)
    }

    static func wrap(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + length(content.count) + content
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var bytes = withUnsafeBytes(of: UInt64(count).bigEndian) { Data($0) }
        while bytes.count > 1, bytes.first == 0x00 {
            bytes = bytes.dropFirst()
        }
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }
}

/// Minimal DER reader: definite-length TLVs, no nesting beyond what the
/// caller asks for.
struct DERReader {
    struct Element {
        let tag: UInt8
        let content: Data
        /// The full TLV encoding (tag + length + content).
        let fullBytes: Data
    }

    private let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readElement() throws -> Element {
        let start = offset
        guard offset < data.count else {
            throw CertificateError.malformedDER("unexpected end of DER")
        }
        let tag = data[offset]
        offset += 1
        let length = try readLength()
        guard offset + length <= data.count else {
            throw CertificateError.malformedDER("length exceeds input")
        }
        let content = data.subdata(in: offset..<(offset + length))
        offset += length
        return Element(tag: tag, content: content, fullBytes: data.subdata(in: start..<offset))
    }

    func expectEnd() throws {
        guard offset == data.count else {
            throw CertificateError.malformedDER("trailing bytes")
        }
    }

    private mutating func readLength() throws -> Int {
        guard offset < data.count else {
            throw CertificateError.malformedDER("missing length")
        }
        let first = data[offset]
        offset += 1
        if first & 0x80 == 0 {
            return Int(first)
        }
        let count = Int(first & 0x7F)
        guard count >= 1, count <= 8, offset + count <= data.count else {
            throw CertificateError.malformedDER("bad long-form length")
        }
        var value = 0
        for _ in 0..<count {
            value = value * 256 + Int(data[offset])
            offset += 1
        }
        return value
    }
}
