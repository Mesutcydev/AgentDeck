//
//  PairingOfferManager.swift
//  Shared — AgentDeck
//
//  §13.2 pairing offers on the companion side: a fresh ≥128-bit nonce per
//  offer, 120-second expiry (the QR window shows the countdown), single-
//  use consumption. Replay of an already-consumed or expired nonce is
//  rejected — pairing replay protection.
//

import Foundation

/// A live pairing offer: what the QR code carries plus its lifetime.
public struct PairingOffer: Sendable, Equatable {
    public let payload: PairingQRPayload
    /// Unix ms.
    public let createdAt: Int64
    /// createdAt + 120 000 (§13.2 normative 120-second expiry).
    public let expiresAt: Int64

    public init(payload: PairingQRPayload, createdAt: Int64, expiresAt: Int64) {
        self.payload = payload
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Remaining lifetime for the visible countdown (§13.2), clamped ≥ 0.
    public func remainingSeconds(now: Int64) -> Int {
        Int(max(0, expiresAt - now) / 1000)
    }

    public func isExpired(now: Int64) -> Bool { now >= expiresAt }
}

/// Outcome of consuming a nonce presented by a connecting client.
public enum PairingNonceConsumption: Sendable, Equatable {
    /// Nonce matched a live, unexpired, unused offer — now consumed.
    case accepted(PairingOffer)
    /// No offer with this nonce exists.
    case unknown
    /// Offer found but already consumed (single-use, §13.2).
    case alreadyUsed
    /// Offer found but past its 120-second window.
    case expired
}

/// Server-side pairing-offer state. One active offer at a time (the QR
/// window); creating a new offer invalidates the previous one. Actor per
/// §25 — pairing attempts arrive concurrently from the network.
public actor PairingOfferManager {
    /// §13.2 normative expiry: 120 seconds.
    public static let lifetimeMilliseconds: Int64 = 120_000

    private var offer: PairingOffer?
    private var consumedNonces: [Data: Int64] = [:]
    private let identity: DeviceIdentity
    private var endpoint: PeerEndpoint

    public init(identity: DeviceIdentity, endpoint: PeerEndpoint) {
        self.identity = identity
        self.endpoint = endpoint
    }

    /// Creates a fresh offer with a new random 128-bit nonce, replacing
    /// any previous offer (its nonce becomes unknown to future clients).
    @discardableResult
    public func createOffer(now: Int64 = Date.unixMillisecondsNow) -> PairingOffer {
        var nonce = Data(count: PairingQRPayload.nonceLength)
        // SecRandomCopyBytes via CryptoKit's SystemRandomNumberGenerator.
        nonce = Data((0..<PairingQRPayload.nonceLength).map { _ in UInt8.random(in: 0...255) })
        let offer = PairingOffer(
            payload: PairingQRPayload(
                deviceID: identity.deviceID,
                publicKeyFingerprint: identity.fingerprint,
                endpoint: endpoint,
                nonce: nonce
            ),
            createdAt: now,
            expiresAt: now + PairingOfferManager.lifetimeMilliseconds
        )
        self.offer = offer
        return offer
    }

    /// The current offer for display (countdown UI), if unexpired.
    public var activeOffer: PairingOffer? {
        guard let offer else { return nil }
        return offer
    }

    /// Updates the advertised endpoint (e.g. after the listener binds to an
    /// OS-assigned port in tests).
    public func update(endpoint: PeerEndpoint) {
        self.endpoint = endpoint
    }

    /// Cancels the active offer (QR window closed).
    public func cancelOffer() {
        offer = nil
    }

    /// Validates and consumes a nonce from a connecting client.
    public func consume(nonce: Data, now: Int64 = Date.unixMillisecondsNow) -> PairingNonceConsumption {
        guard let offer, offer.payload.nonce == nonce else {
            return .unknown
        }
        if offer.isExpired(now: now) {
            return .expired
        }
        if consumedNonces[nonce] != nil {
            return .alreadyUsed
        }
        consumedNonces[nonce] = now
        return .accepted(offer)
    }
}
