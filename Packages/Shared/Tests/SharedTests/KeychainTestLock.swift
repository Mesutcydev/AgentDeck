//
//  KeychainTestLock.swift
//  SharedTests — AgentDeck
//
//  Serializes resource-sensitive integration tests (Keychain, SecKey, PTY)
//  that race when Swift Testing runs suites in parallel.
//

import Foundation

private actor IntegrationTestGate {
    static let shared = IntegrationTestGate()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            locked = false
        }
    }
}

enum IntegrationTestQueue {
    static func async<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await IntegrationTestGate.shared.run(body)
    }
}

enum KeychainTestLock {
    static func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await IntegrationTestGate.shared.run(body)
    }
}

enum PTYTestGate {
    static func run<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        try await IntegrationTestGate.shared.run(body)
    }
}
