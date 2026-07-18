//
//  main.swift
//  agentdeck-relay — AgentDeck §14.3 notification relay
//
//  Fails fast at startup when RELAY_SIGNING_PUBLIC_KEY is missing or
//  invalid — a relay without the companion's public key can verify
//  nothing, so a random fallback key would silently accept zero
//  legitimate requests while looking healthy.
//

import CryptoKit
import Foundation
import RelayCore
import Shared

@main
struct AgentDeckRelay {
    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["RELAY_HOST"] ?? "127.0.0.1"
        let port = Int(environment["PORT"] ?? "8787") ?? 8787

        guard let keyText = environment["RELAY_SIGNING_PUBLIC_KEY"], !keyText.isEmpty else {
            failFast("RELAY_SIGNING_PUBLIC_KEY is not set (expected a base64 Ed25519 public key from the companion)")
        }
        guard let keyData = Data(base64Encoded: keyText),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            failFast("RELAY_SIGNING_PUBLIC_KEY is not a valid base64 Ed25519 public key")
        }

        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: host,
            port: port,
            signingPublicKey: publicKey,
            apnsMode: .simulated
        ), outbox: outbox)

        print("agentdeck-relay listening on \(host):\(port)")
        print("APNs delivery is SIMULATED: notifications are recorded in the in-memory outbox (capacity \(SimulatedAPNsOutbox.defaultCapacity)) and never reach a device until a real APNs provider is configured (NEEDS-HUMAN #2, #7).")
        if host != "127.0.0.1", host != "::1", host != "localhost" {
            print("WARNING: relay is bound beyond loopback. The wire protocol is plain HTTP/1 — remote exposure requires TLS termination in front (ADR-0020).")
        }
        try channel.closeFuture.wait()
    }

    private static func failFast(_ message: String) -> Never {
        FileHandle.standardError.write(Data("agentdeck-relay: error: \(message)\n".utf8))
        Foundation.exit(1)
    }
}
