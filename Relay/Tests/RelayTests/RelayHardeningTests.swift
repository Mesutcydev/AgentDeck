import CryptoKit
import Foundation
import RelayCore
import Shared
import Testing

@Suite("relay hardening (2026-07-18 audit wave)")
struct RelayHardeningTests {
    // MARK: - (a) request-body cap → 413

    @Test("relay rejects oversized bodies with 413 and records nothing")
    func rejectsOversizedBody() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            signingPublicKey: privateKey.publicKey
        ), outbox: outbox)
        defer { try? channel.close().wait() }

        let port = channel.localAddress?.port ?? 0
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/notify")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data(repeating: 0x61, count: 64 * 1024 + 1)
        let (_, response) = try syncData(for: urlRequest)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 413)
        #expect(outbox.deliveries.isEmpty)
    }

    // MARK: - (b) replay cache → 409 until expiration passes

    @Test("relay rejects a replayed signed request until its expiration")
    func rejectsReplay() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            signingPublicKey: privateKey.publicKey
        ), outbox: outbox)
        defer { try? channel.close().wait() }

        let port = channel.localAddress?.port ?? 0
        let body = try signedBody(privateKey: privateKey)
        #expect(try post(body, port: port) == 202)
        #expect(try post(body, port: port) == 409)
        #expect(outbox.deliveries.count == 1)

        // A distinct request (new session ID) is unaffected.
        let other = try signedBody(privateKey: privateKey)
        #expect(try post(other, port: port) == 202)
        #expect(outbox.deliveries.count == 2)
    }

    @Test("replay cache evicts entries once the request expiration passes")
    func replayCacheEvictsAfterExpiration() {
        let cache = RelayReplayCache()
        let digest = Data(SHA256.hash(data: Data("request".utf8)))
        #expect(cache.checkAndInsert(digest, expiration: 1_000, now: 500))
        #expect(!cache.checkAndInsert(digest, expiration: 1_000, now: 600))
        #expect(cache.count == 1)
        // Expiration passed: the old entry no longer blocks re-insertion
        // (the request itself would now fail expiry validation anyway).
        #expect(cache.checkAndInsert(digest, expiration: 2_000, now: 1_001))
    }

    @Test("replay cache is fail-safe at capacity")
    func replayCacheRejectsWhenFull() {
        let cache = RelayReplayCache(maximumEntries: 1)
        #expect(cache.checkAndInsert(Data("a".utf8), expiration: 1_000, now: 500))
        #expect(!cache.checkAndInsert(Data("b".utf8), expiration: 1_000, now: 500))
    }

    // MARK: - (c) per-source-IP rate limit → 429 + Retry-After

    @Test("relay rate-limits a flooding source IP with 429 and Retry-After")
    func rateLimitsSourceIP() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            signingPublicKey: privateKey.publicKey,
            rateLimitPerWindow: 2
        ), outbox: outbox)
        defer { try? channel.close().wait() }

        let port = channel.localAddress?.port ?? 0
        // Bodies are invalid ({}), but the limiter gates before parsing.
        #expect(try post(Data("{}".utf8), port: port) == 400)
        #expect(try post(Data("{}".utf8), port: port) == 400)

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/notify")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data("{}".utf8)
        let (_, response) = try syncData(for: urlRequest)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 429)
        let retryAfter = try #require(http.value(forHTTPHeaderField: "Retry-After"))
        #expect((Int(retryAfter) ?? 0) >= 1)
        #expect(outbox.deliveries.isEmpty)
    }

    @Test("rate limiter resets after the window slides")
    func rateLimiterWindowResets() {
        let limiter = RelayRateLimiter(limit: 1, windowMilliseconds: 60_000)
        #expect(limiter.check("10.0.0.1", now: 0) == nil)
        #expect(limiter.check("10.0.0.1", now: 1_000) != nil)
        #expect(limiter.check("10.0.0.2", now: 1_000) == nil)
        #expect(limiter.check("10.0.0.1", now: 60_001) == nil)
    }

    // MARK: - (f) simulated outbox ring buffer

    @Test("simulated outbox drops oldest deliveries past capacity")
    func outboxRingBufferDropsOldest() throws {
        let outbox = SimulatedAPNsOutbox(capacity: 2)
        for index in 0..<3 {
            outbox.record(RelayNotifyRequest(
                destinationToken: try #require(PushDestinationToken("sim")),
                eventType: .sessionCompleted,
                sessionID: SessionID.random(),
                projectAlias: nil,
                notificationText: "n\(index)",
                expiration: Date.unixMillisecondsNow + 60_000
            ))
        }
        #expect(outbox.deliveries.count == 2)
        #expect(outbox.deliveries.map(\.notificationText) == ["n1", "n2"])
        #expect(outbox.droppedCount == 1)
    }

    // MARK: - helpers

    private func signedBody(privateKey: Curve25519.Signing.PrivateKey) throws -> Data {
        var request = RelayNotifyRequest(
            destinationToken: try #require(PushDestinationToken("sim-token")),
            eventType: .sessionCompleted,
            sessionID: SessionID.random(),
            projectAlias: "Demo",
            notificationText: "Done.",
            expiration: Date.unixMillisecondsNow + 120_000
        )
        try RelaySigning.sign(&request, privateKey: privateKey)
        return try request.toJSONValue().canonicalBytes()
    }

    private func post(_ body: Data, port: Int) throws -> Int {
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/notify")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        let (_, response) = try syncData(for: urlRequest)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }
}
