//
//  PeerListener.swift
//  Shared — AgentDeck
//
//  §13.4 listener: Network.framework TLS WebSocket server for §9
//  connections, with Bonjour advertisement (§13.5 mode 2 — discovery and
//  onboarding only). Each accepted NWConnection becomes a PeerConnection
//  signing with the device's §13.1 identity key.
//

import CryptoKit
import Foundation
import Network

#if os(macOS)
public actor PeerListener {
    private let listener: NWListener
    private let signingPrivateKey: Curve25519.Signing.PrivateKey
    private let counter: MetricsCounter?
    private let heartbeatIntervalMilliseconds: UInt64
    private var isStarted = false
    private var isReady = false

    /// Accepted connections, in arrival order.
    public let connections: AsyncStream<PeerConnection>
    private let continuation: AsyncStream<PeerConnection>.Continuation

    /// The port the listener is bound to (valid after `start()`).
    public private(set) var boundPort: UInt16?

    /// - Parameters:
    ///   - tlsIdentity: the device's TLS credential (server certificate).
    ///   - port: 0 = OS-assigned (tests); production uses PeerEndpoint.defaultPort.
    ///   - serviceName: Bonjour name; nil disables advertisement.
    ///   - signingPrivateKey: the §13.1 Ed25519 identity key for frames.
    public init(
        tlsIdentity: TLSIdentity,
        port: UInt16,
        serviceName: String?,
        signingPrivateKey: Curve25519.Signing.PrivateKey,
        counter: MetricsCounter? = nil,
        heartbeatIntervalMilliseconds: UInt64 = PeerConnection.defaultHeartbeatIntervalMilliseconds
    ) throws {
        self.signingPrivateKey = signingPrivateKey
        self.counter = counter
        self.heartbeatIntervalMilliseconds = heartbeatIntervalMilliseconds

        let parameters = try TransportSecurity.serverParameters(tlsIdentity: tlsIdentity)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PeerListenerError.invalidPort(port)
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: "_agentdeck._tcp")
        }
        self.listener = listener

        var continuation: AsyncStream<PeerConnection>.Continuation?
        self.connections = AsyncStream { continuation = $0 }
        guard let continuation else {
            throw PeerListenerError.listenerFailed("stream setup failed")
        }
        self.continuation = continuation
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        listener.newConnectionHandler = { [weak self] nwConnection in
            guard let self else { return }
            Task {
                let peer = await self.makeConnection(nwConnection)
                await peer.start()
                self.continuation.yield(peer)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    Task { await self.setBoundPort(port) }
                }
                Task { await self.markReady() }
            case .failed, .cancelled:
                Task { await self.markReady() }
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "\(ProductNaming.logSubsystem).listener"))
    }

    private func setBoundPort(_ port: UInt16) {
        boundPort = port
    }

    private func markReady() {
        isReady = true
    }

    /// Waits until the listener is ready (or has failed/cancelled).
    public func waitForReady(timeoutMilliseconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000.0)
        while !isReady {
            if Date() >= deadline {
                throw PeerListenerError.listenerFailed("ready timeout")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func makeConnection(_ nwConnection: NWConnection) -> PeerConnection {
        PeerConnection(
            connection: nwConnection,
            localPrivateKey: signingPrivateKey,
            counter: counter,
            heartbeatIntervalMilliseconds: heartbeatIntervalMilliseconds
        )
    }

    public func stop() {
        listener.cancel()
        continuation.finish()
        isStarted = false
    }
}

public enum PeerListenerError: Error, Equatable {
    case invalidPort(UInt16)
    case listenerFailed(String)
}
#endif
