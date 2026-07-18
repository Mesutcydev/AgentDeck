//
//  RelaySigning.swift
//  Shared — AgentDeck
//
//  §14.3 Ed25519 authentication for relay POST /v1/notify bodies.
//

import CryptoKit
import Foundation

public enum RelaySigning {
    /// Signs the canonical JSON body with `signature` absent.
    public static func sign(
        _ request: inout RelayNotifyRequest,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws {
        let bytes = try canonicalSigningBytes(for: request)
        request.signature = try privateKey.signature(for: bytes)
    }

    public static func verify(
        _ request: RelayNotifyRequest,
        publicKey: Curve25519.Signing.PublicKey
    ) -> Bool {
        guard let signature = request.signature else { return false }
        guard let bytes = try? canonicalSigningBytes(for: request) else { return false }
        return publicKey.isValidSignature(signature, for: bytes)
    }

    private static func canonicalSigningBytes(for request: RelayNotifyRequest) throws -> Data {
        var unsigned = request
        unsigned.signature = nil
        return try unsigned.toJSONValue().canonicalBytes()
    }
}

#if os(macOS)

/// Companion-side relay dispatch over HTTP POST /v1/notify.
public struct RelayHTTPClient: Sendable {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var signingPrivateKey: Curve25519.Signing.PrivateKey

        public init(baseURL: URL, signingPrivateKey: Curve25519.Signing.PrivateKey) {
            self.baseURL = baseURL
            self.signingPrivateKey = signingPrivateKey
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession

    public init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func send(_ request: RelayNotifyRequest) async throws {
        var signed = request
        try RelaySigning.sign(&signed, privateKey: configuration.signingPrivateKey)
        try RelayNotifyValidator.validate(signed)

        let endpoint = configuration.baseURL.appendingPathComponent("v1/notify")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try signed.toJSONValue().canonicalBytes()

        let (_, response) = try await urlSession.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayNotificationError.invalidPayload("relay HTTP failure")
        }
    }
}

#endif
