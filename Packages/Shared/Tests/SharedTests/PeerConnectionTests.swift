//
//  PeerConnectionTests.swift
//  SharedTests — AgentDeck
//
//  §9 incoming-seq enforcement over a live loopback connection: a
//  duplicate seq carrying a FRESH nonce passes the replay cache but must
//  never be delivered twice; gap/buffer behavior is unchanged.
//
//  Silence is proven WITHOUT abandoning a read (a cancelled readFrame
//  waiter is never resumed): after each duplicate we send a known-good
//  frame — in-order delivery means the next read must return the good
//  frame, not the duplicate.
//

import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import Shared

@Suite("§9 duplicate-seq delivery (loopback)", .serialized)
struct PeerConnectionDuplicateTests {
    private let signingKey = Curve25519.Signing.PrivateKey()

    /// A loopback pair: a raw server-side NWConnection (frames crafted by
    /// hand) feeding a real PeerConnection on the client side.
    private func makePair() async throws -> (raw: NWConnection, peer: PeerConnection) {
        let listener = try NWListener(using: .tcp)
        let accepted = Mutex<NWConnection?>(nil)
        listener.newConnectionHandler = { connection in
            accepted.withLock { $0 = connection }
        }
        listener.start(queue: DispatchQueue(label: "test.loopback.listener"))
        // start() is asynchronous: connecting before the listener reaches
        // .ready can be refused by the kernel (loopback race).
        try await waitUntilListenerReady(listener)
        let port = try #require(listener.port)

        let clientConnection = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port),
            using: .tcp
        )
        let peer = PeerConnection(
            connection: clientConnection,
            localPrivateKey: signingKey
        )
        await peer.start()
        try await peer.waitForReady(timeoutMilliseconds: 5_000)

        let raw = try await waitForAccepted(in: accepted)
        try await waitUntilReady(raw)
        return (raw, peer)
    }

    private func waitForAccepted(in box: borrowing Mutex<NWConnection?>) async throws -> NWConnection {
        for _ in 0..<500 {
            if let connection = box.withLock({ $0 }) {
                return connection
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PeerConnectionError.readyTimeout
    }

    private func waitUntilListenerReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let shouldResume = resumed.withLock { value -> Bool in
                    if value { return false }
                    value = true
                    return true
                }
                guard shouldResume else { return }
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
        }
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let shouldResume = resumed.withLock { value -> Bool in
                    if value { return false }
                    value = true
                    return true
                }
                guard shouldResume else { return }
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.loopback.raw"))
        }
    }

    private func makeFrame(seq: UInt64) -> Frame {
        Frame(
            type: .heartbeat,
            seq: seq,
            ack: 0,
            timestamp: Date.unixMillisecondsNow,
            nonce: Data((0..<Frame.nonceLength).map { _ in UInt8.random(in: 0...255) }),
            payload: .object([:])
        )
    }

    private func sendRaw(_ frame: Frame, over connection: NWConnection) async throws {
        let payload = try FrameCodec.encode(frame, signingWith: signingKey)
        var data = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        data.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        // Let the receive loop process this frame before the next send so
        // delivery order is deterministic.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test("a duplicate seq with a fresh nonce is dropped, never delivered twice")
    func duplicateSeqDropped() async throws {
        let (raw, peer) = try await makePair()
        try await sendRaw(makeFrame(seq: 1), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 1)

        // Same seq, fresh nonces: the replay cache passes them, the
        // tracker must drop them (§9).
        try await sendRaw(makeFrame(seq: 1), over: raw)
        try await sendRaw(makeFrame(seq: 1), over: raw)
        try await sendRaw(makeFrame(seq: 2), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 2,
                "the next delivery must be seq 2 — the duplicates were dropped")

        // An already-acked duplicate from further back drops too.
        try await sendRaw(makeFrame(seq: 1), over: raw)
        try await sendRaw(makeFrame(seq: 3), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 3)

        await peer.close()
        raw.cancel()
    }

    @Test("gap/buffer behavior is unchanged: out-of-order frames flow, their duplicates drop")
    func outOfOrderStillFlows() async throws {
        let (raw, peer) = try await makePair()
        try await sendRaw(makeFrame(seq: 1), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 1)

        // Ahead of a gap: buffered by the tracker, still delivered (the
        // pre-existing delivery semantics are unchanged).
        try await sendRaw(makeFrame(seq: 3), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 3)

        // A duplicate of the BUFFERED seq also drops.
        try await sendRaw(makeFrame(seq: 3), over: raw)
        // The gap fills; the filler frame is delivered exactly once.
        try await sendRaw(makeFrame(seq: 2), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 2,
                "the gap filler, not the buffered duplicate")

        // Duplicates of acked seqs drop; delivery continues.
        try await sendRaw(makeFrame(seq: 2), over: raw)
        try await sendRaw(makeFrame(seq: 1), over: raw)
        try await sendRaw(makeFrame(seq: 4), over: raw)
        #expect(try await peer.readFrame()?.frame.seq == 4)

        await peer.close()
        raw.cancel()
    }
}
