//
//  ApprovalResolver.swift
//  Shared — AgentDeck
//
//  Idempotent approval resolution (SPEC §9): duplicate or retried resolves
//  — including after reconnect — return the ORIGINAL outcome
//  ("already resolved") and never re-apply a decision. First-come wins
//  across devices (§13.3). Approval TTL (§15.3): a request past its expiry
//  resolves to a terminal EXPIRED state — recorded here — and every later
//  decision is rejected with `ApprovalError.requestExpired`.
//  Actor per SPEC §25.
//

import Foundation

public actor ApprovalResolver {
    private var requests: [ApprovalRequestID: ApprovalRequest] = [:]
    private var resolutions: [ApprovalRequestID: ApprovalResolution] = [:]
    private let nowProvider: @Sendable () -> Int64
    /// TTL applied to requests without an explicit `expiresAt`.
    private let defaultTTLMilliseconds: Int64

    public init(
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow },
        defaultTTLMilliseconds: Int64 = ApprovalRequest.defaultTTLMilliseconds
    ) {
        self.nowProvider = nowProvider
        self.defaultTTLMilliseconds = defaultTTLMilliseconds
    }

    /// Registers a pending request. Re-registering the SAME request id with
    /// an identical request is an idempotent no-op (safe retry); a different
    /// request under the same id is a data-integrity error.
    public func register(_ request: ApprovalRequest) throws {
        if let existing = requests[request.id] {
            guard existing == request else {
                throw ApprovalError.duplicateRegistration(request.id)
            }
            return
        }
        requests[request.id] = request
    }

    /// Resolves a request. §9 idempotency: if the request was already
    /// resolved, the ORIGINAL resolution is returned with
    /// `wasAlreadyResolved == true`; the new decision is NOT applied.
    /// - Throws: `ApprovalError.unknownRequest` when the id was never
    ///   registered (a resolver cannot decide what it never saw), and
    ///   `ApprovalError.requestExpired` when the request is in — or has
    ///   just fallen into — the terminal expired state.
    public func resolve(
        requestID: ApprovalRequestID,
        decision: ApprovalDecision,
        now: Int64? = nil
    ) throws -> ApprovalResolution {
        let now = now ?? nowProvider()
        if let existing = resolutions[requestID] {
            if existing.expired {
                throw ApprovalError.requestExpired(requestID)
            }
            return ApprovalResolution(
                requestID: requestID,
                decision: existing.decision,
                wasAlreadyResolved: true
            )
        }
        guard let request = requests[requestID] else {
            throw ApprovalError.unknownRequest(requestID)
        }
        guard !request.isExpired(at: now, defaultTTLMilliseconds: defaultTTLMilliseconds) else {
            // Record the terminal expired state BEFORE rejecting, so the
            // outcome is durable and every later decision is rejected too.
            _ = try expire(request, now: now)
            throw ApprovalError.requestExpired(requestID)
        }
        let resolution = ApprovalResolution(
            requestID: requestID,
            decision: decision,
            wasAlreadyResolved: false
        )
        resolutions[requestID] = resolution
        return resolution
    }

    /// Sweeps every pending request past its TTL into the terminal expired
    /// state. Returns the newly-recorded expired resolutions (already
    /// expired or decided requests are not re-touched).
    @discardableResult
    public func sweepExpired(now: Int64? = nil) throws -> [ApprovalResolution] {
        let now = now ?? nowProvider()
        var expired: [ApprovalResolution] = []
        for request in requests.values
        where resolutions[request.id] == nil
            && request.isExpired(at: now, defaultTTLMilliseconds: defaultTTLMilliseconds) {
            expired.append(try expire(request, now: now))
        }
        return expired.sorted { $0.requestID.wireString < $1.requestID.wireString }
    }

    /// Expires one request when (and only when) it is pending AND past its
    /// TTL. Returns true when this call recorded the terminal expiry.
    public func expireIfNeeded(requestID: ApprovalRequestID, now: Int64? = nil) throws -> Bool {
        let now = now ?? nowProvider()
        guard resolutions[requestID] == nil,
              let request = requests[requestID],
              request.isExpired(at: now, defaultTTLMilliseconds: defaultTTLMilliseconds) else {
            return false
        }
        _ = try expire(request, now: now)
        return true
    }

    public func request(for requestID: ApprovalRequestID) -> ApprovalRequest? {
        requests[requestID]
    }

    public func resolution(for requestID: ApprovalRequestID) -> ApprovalResolution? {
        resolutions[requestID]
    }

    public var pendingRequests: [ApprovalRequest] {
        requests.values.filter { resolutions[$0.id] == nil }
    }

    /// Records the terminal expired state for `request`. The carried
    /// decision is a deny — a recording artifact, never an authorization.
    private func expire(_ request: ApprovalRequest, now: Int64) throws -> ApprovalResolution {
        let resolution = ApprovalResolution(
            requestID: request.id,
            decision: try ApprovalDecision(choice: .deny, decidedAt: now),
            wasAlreadyResolved: false,
            expired: true
        )
        resolutions[request.id] = resolution
        return resolution
    }
}
