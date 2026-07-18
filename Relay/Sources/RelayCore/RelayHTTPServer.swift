//
//  RelayHTTPServer.swift
//  RelayCore — AgentDeck
//
//  §14.3 POST /v1/notify with Ed25519 verification and simulated APNs delivery.
//
//  Hardening (2026-07-18 audit wave):
//  - request bodies capped (`maximumBodyBytes`, 413 Payload Too Large)
//  - replay cache: accepted signed requests are hashed and rejected until
//    their own `expiration` passes (409 Conflict)
//  - per-source-IP fixed-window rate limit (429 + Retry-After)
//  - loopback bind by default; remote exposure requires TLS termination
//    in front (ADR-0020)
//

import CryptoKit
import Foundation
import NIO
import NIOHTTP1
import Shared

public struct RelayServerConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var signingPublicKey: Curve25519.Signing.PublicKey
    public var apnsMode: APNsDeliveryMode
    /// Hard cap on a single request body; larger requests get 413.
    public var maximumBodyBytes: Int
    /// Requests allowed per source IP inside one fixed window.
    public var rateLimitPerWindow: Int
    public var rateLimitWindowMilliseconds: Int64
    /// Live replay-cache entries; at capacity new requests are denied
    /// (fail-safe, mirroring the §9 ReplayCache policy).
    public var replayCacheCapacity: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 8787,
        signingPublicKey: Curve25519.Signing.PublicKey,
        apnsMode: APNsDeliveryMode = .simulated,
        maximumBodyBytes: Int = 64 * 1024,
        rateLimitPerWindow: Int = 60,
        rateLimitWindowMilliseconds: Int64 = 60_000,
        replayCacheCapacity: Int = 10_000
    ) {
        self.host = host
        self.port = port
        self.signingPublicKey = signingPublicKey
        self.apnsMode = apnsMode
        self.maximumBodyBytes = maximumBodyBytes
        self.rateLimitPerWindow = rateLimitPerWindow
        self.rateLimitWindowMilliseconds = rateLimitWindowMilliseconds
        self.replayCacheCapacity = replayCacheCapacity
    }
}

public enum APNsDeliveryMode: Sendable {
    case simulated
    case disabled
}

/// Ring-buffered record of simulated APNs deliveries: the oldest entries
/// are dropped past `capacity` so a flooded relay cannot grow memory
/// without bound. Delivery is a stand-in for the real APNs HTTP/2
/// provider path (NEEDS-HUMAN #2, #7) — nothing here leaves the process.
public final class SimulatedAPNsOutbox: @unchecked Sendable {
    public static let defaultCapacity = 500

    private let lock = NSLock()
    private var stored: [RelayNotifyRequest] = []
    private var dropped = 0
    private let capacity: Int

    public init(capacity: Int = SimulatedAPNsOutbox.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var deliveries: [RelayNotifyRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Entries evicted by the capacity cap (diagnostic visibility).
    public var droppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    public func record(_ request: RelayNotifyRequest) {
        lock.lock()
        stored.append(request)
        if stored.count > capacity {
            stored.removeFirst(stored.count - capacity)
            dropped += 1
        }
        lock.unlock()
    }
}

/// Replay protection for accepted signed notify requests: the SHA-256 of
/// the canonical signed body is kept until the request's own `expiration`
/// passes — a captured request replays for zero additional time instead
/// of its full TTL. Expired entries are purged lazily on insert; at
/// capacity NEW requests are rejected (fail-safe: evicting live entries
/// would reopen a replay window).
public final class RelayReplayCache: @unchecked Sendable {
    public static let defaultMaximumEntries = 10_000

    private let lock = NSLock()
    private var entries: [Data: Int64] = [:] // body digest → request expiration (unix ms)
    private let maximumEntries: Int

    public init(maximumEntries: Int = RelayReplayCache.defaultMaximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
    }

    /// Returns true when the digest is new (or its previous entry expired)
    /// and is now recorded; false on replay or when the cache is full.
    public func checkAndInsert(
        _ digest: Data,
        expiration: Int64,
        now: Int64 = Date.unixMillisecondsNow
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { $0.value >= now }
        if let seen = entries[digest], seen >= now {
            return false
        }
        guard entries.count < maximumEntries else {
            return false
        }
        entries[digest] = expiration
        return true
    }

    /// Number of live entries (test/diagnostic visibility).
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}

/// Per-source-IP fixed-window rate limiter (§13.4-style fail-closed
/// policy, synchronous for the NIO pipeline).
public final class RelayRateLimiter: @unchecked Sendable {
    private struct Window {
        var start: Int64
        var count: Int
    }

    private let lock = NSLock()
    private var windows: [String: Window] = [:]
    private let limit: Int
    private let windowMilliseconds: Int64

    public init(limit: Int, windowMilliseconds: Int64) {
        self.limit = max(1, limit)
        self.windowMilliseconds = max(1, windowMilliseconds)
    }

    /// Records an attempt; returns nil when allowed, otherwise the number
    /// of whole seconds until the current window resets (Retry-After).
    public func check(_ key: String, now: Int64 = Date.unixMillisecondsNow) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if var window = windows[key], now - window.start < windowMilliseconds {
            guard window.count < limit else {
                let remaining = window.start + windowMilliseconds - now
                return max(1, Int((remaining + 999) / 1000))
            }
            window.count += 1
            windows[key] = window
            return nil
        }
        windows[key] = Window(start: now, count: 1)
        return nil
    }
}

public enum RelayHTTPServer {
    public static func start(
        configuration: RelayServerConfiguration,
        outbox: SimulatedAPNsOutbox,
        group: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    ) throws -> Channel {
        let rateLimiter = RelayRateLimiter(
            limit: configuration.rateLimitPerWindow,
            windowMilliseconds: configuration.rateLimitWindowMilliseconds
        )
        let replayCache = RelayReplayCache(maximumEntries: configuration.replayCacheCapacity)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(RelayNotifyHandler(
                        signingPublicKey: configuration.signingPublicKey,
                        apnsMode: configuration.apnsMode,
                        outbox: outbox,
                        rateLimiter: rateLimiter,
                        replayCache: replayCache,
                        maximumBodyBytes: configuration.maximumBodyBytes
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        return try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
    }
}

private final class RelayNotifyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Per-connection request state: rejected requests are drained without
    /// a second response so keep-alive stays well-formed.
    private enum State {
        case idle
        case receiving
        case discarding
    }

    private let signingPublicKey: Curve25519.Signing.PublicKey
    private let apnsMode: APNsDeliveryMode
    private let outbox: SimulatedAPNsOutbox
    private let rateLimiter: RelayRateLimiter
    private let replayCache: RelayReplayCache
    private let maximumBodyBytes: Int
    private var requestBody = Data()
    private var state: State = .idle

    init(
        signingPublicKey: Curve25519.Signing.PublicKey,
        apnsMode: APNsDeliveryMode,
        outbox: SimulatedAPNsOutbox,
        rateLimiter: RelayRateLimiter,
        replayCache: RelayReplayCache,
        maximumBodyBytes: Int
    ) {
        self.signingPublicKey = signingPublicKey
        self.apnsMode = apnsMode
        self.outbox = outbox
        self.rateLimiter = rateLimiter
        self.replayCache = replayCache
        self.maximumBodyBytes = maximumBodyBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            handleHead(context: context, head: head)
        case .body(let buffer):
            guard state == .receiving else { return }
            requestBody.append(contentsOf: buffer.readableBytesView)
            if requestBody.count > maximumBodyBytes {
                respond(context: context, status: .payloadTooLarge, body: "payload too large")
                state = .discarding
            }
        case .end:
            guard state == .receiving else {
                state = .idle
                return
            }
            state = .idle
            handleRequest(context: context)
        }
    }

    private func handleHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
        if head.method == .GET, head.uri == "/healthz" {
            respond(context: context, status: .ok, body: "ok")
            state = .discarding
            return
        }
        let source = context.channel.remoteAddress?.ipAddress ?? "unknown"
        if let retryAfter = rateLimiter.check(source) {
            respond(
                context: context,
                status: .tooManyRequests,
                body: "rate limit exceeded",
                extraHeaders: [("Retry-After", String(retryAfter))]
            )
            state = .discarding
            return
        }
        guard head.uri == "/v1/notify", head.method == .POST else {
            respond(context: context, status: .notFound, body: "not found")
            state = .discarding
            return
        }
        if let lengthText = head.headers["Content-Length"].first,
           let length = Int(lengthText),
           length > maximumBodyBytes {
            respond(context: context, status: .payloadTooLarge, body: "payload too large")
            state = .discarding
            return
        }
        requestBody.removeAll(keepingCapacity: true)
        state = .receiving
    }

    private func handleRequest(context: ChannelHandlerContext) {
        do {
            let json = try JSONParser.parse(requestBody)
            if case .object(let entries) = json {
                var object: [String: Any] = [:]
                for (key, value) in entries {
                    object[key] = value.foundationValue
                }
                try RelayNotifyValidator.validateJSONObject(object)
            }
            let request = try RelayNotifyRequest(jsonValue: json)
            guard RelaySigning.verify(request, publicKey: signingPublicKey) else {
                respond(context: context, status: .unauthorized, body: "invalid signature")
                return
            }
            try RelayNotifyValidator.validate(request)
            let digest = Data(SHA256.hash(data: requestBody))
            guard replayCache.checkAndInsert(digest, expiration: request.expiration) else {
                respond(context: context, status: .conflict, body: "replay detected")
                return
            }
            switch apnsMode {
            case .simulated:
                outbox.record(request)
            case .disabled:
                break
            }
            respond(context: context, status: .accepted, body: "accepted")
        } catch {
            respond(context: context, status: .badRequest, body: "invalid payload")
        }
    }

    private func respond(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String,
        extraHeaders: [(String, String)] = []
    ) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }
        let buffer = context.channel.allocator.buffer(string: body)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let entries): return Dictionary(uniqueKeysWithValues: entries.map { ($0, $1.foundationValue) })
        }
    }
}
