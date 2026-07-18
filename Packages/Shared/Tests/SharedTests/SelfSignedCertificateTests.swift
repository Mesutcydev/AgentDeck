//
//  SelfSignedCertificateTests.swift
//  SharedTests — AgentDeck
//
//  Endpoint-binding certificate tests: DER parses via Security framework,
//  self-signature verifies, enclosed public key equals the identity key
//  (the §13.4 binding property), tampering is rejected.
//

import CryptoKit
import Foundation
import Security
import Testing
@testable import Shared

@Suite("§13.4 endpoint-binding certificate")
struct SelfSignedCertificateTests {
    private let notBefore = Date(timeIntervalSince1970: 1_752_700_000)
    private let notAfter = Date(timeIntervalSince1970: 1_852_700_000)

    private func makeCertificate(
        key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()
    ) throws -> (der: Data, key: Curve25519.Signing.PrivateKey) {
        let der = try SelfSignedCertificate.ed25519(
            commonName: "AgentDeck Test Mac",
            publicKey: key.publicKey,
            signWith: key,
            notBefore: notBefore,
            notAfter: notAfter,
            serial: 0x0102030405060708
        )
        return (der, key)
    }

    @Test("Security framework parses the generated certificate")
    func secCertificateParses() throws {
        let (der, _) = try makeCertificate()
        #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
    }

    @Test("parse+verify returns the identity public key (the binding property)")
    func parseAndVerify() throws {
        let (der, key) = try makeCertificate()
        let parsed = try SelfSignedCertificate.parseAndVerifyEd25519(der: der)
        #expect(parsed.publicKey.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(parsed.signature.count == 64)
    }

    @Test("the certificate's public key matches what Security reports")
    func secKeyMatch() throws {
        let (der, key) = try makeCertificate()
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let secKey = try #require(SecCertificateCopyKey(certificate))
        var error: Unmanaged<CFError>?
        let external = try #require(SecKeyCopyExternalRepresentation(secKey, &error) as Data?)
        // Security may prefix Ed25519 keys (0x04 uncompressed-point style)
        // or return raw 32 bytes; accept exactly one.
        let matchesRaw = external == key.publicKey.rawRepresentation
        let matchesPrefixed = external.count == 33
            && external.dropFirst() == key.publicKey.rawRepresentation
        #expect(matchesRaw || matchesPrefixed,
                "SecCertificate key must equal the identity key, got \(external.count) bytes")
    }

    @Test("tampered certificates fail verification")
    func tamperRejected() throws {
        let (der, _) = try makeCertificate()
        // Flip a bit inside the TBS region (after the outer SEQUENCE header).
        var tampered = der
        tampered[20] ^= 0x01
        #expect(throws: CertificateError.self) {
            _ = try SelfSignedCertificate.parseAndVerifyEd25519(der: tampered)
        }
        // A certificate for a DIFFERENT key verifies but carries that
        // other key — endpoint binding (fingerprint comparison) rejects it.
        let otherKey = Curve25519.Signing.PrivateKey()
        let other = try SelfSignedCertificate.ed25519(
            commonName: "AgentDeck Test Mac",
            publicKey: otherKey.publicKey,
            signWith: otherKey,
            notBefore: notBefore,
            notAfter: notAfter,
            serial: 0x0102030405060708
        )
        let parsedOther = try SelfSignedCertificate.parseAndVerifyEd25519(der: other)
        let parsed = try SelfSignedCertificate.parseAndVerifyEd25519(der: der)
        #expect(parsedOther.publicKey.rawRepresentation != parsed.publicKey.rawRepresentation)
    }

    @Test("truncated and malformed DER is rejected, not crashed")
    func malformedRejected() throws {
        let (der, _) = try makeCertificate()
        #expect(throws: CertificateError.self) {
            _ = try SelfSignedCertificate.parseAndVerifyEd25519(der: der.prefix(40))
        }
        #expect(throws: CertificateError.self) {
            _ = try SelfSignedCertificate.parseAndVerifyEd25519(der: Data([0x30, 0x03, 0x02, 0x01, 0x05]))
        }
    }
}
