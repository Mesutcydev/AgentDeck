import Foundation
import Testing
@testable import Shared

@Suite("Local CLI protocol")
struct LocalControlProtocolTests {
    @Test("request and response round trip without losing opaque arguments")
    func roundTrip() throws {
        let request = LocalControlRequest(
            command: .run, provider: "claude", projectPath: "/tmp/project with spaces",
            arguments: ["--model", "opus", "literal;not-shell"]
        )
        let data = try JSONEncoder().encode(request)
        #expect(data.count < LocalControlRequest.maximumEncodedBytes)
        #expect(try JSONDecoder().decode(LocalControlRequest.self, from: data) == request)

        let response = LocalControlResponse(
            requestID: request.id, ok: true, message: "ready", sessionID: UUID().uuidString,
            streamFollows: true
        )
        #expect(try JSONDecoder().decode(LocalControlResponse.self, from: JSONEncoder().encode(response)) == response)
    }

    @Test("socket lives in the user-only application support directory")
    func socketPath() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(LocalControlPath.socketURL(homeDirectory: home).path == "/Users/example/Library/Application Support/AgentDeck/control.sock")
    }

    @Test("terminal stream packets round trip opaque bytes and resize")
    func terminalPackets() throws {
        let packets = [
            LocalTerminalMessage(kind: .input, data: Data([0x00, 0x0A, 0xFF])),
            LocalTerminalMessage(kind: .output, data: Data("hello".utf8)),
            LocalTerminalMessage(kind: .resize, columns: 120, rows: 40),
            LocalTerminalMessage(kind: .interrupt),
            LocalTerminalMessage(kind: .detach),
        ]
        for packet in packets {
            let encoded = try JSONEncoder().encode(packet)
            #expect(try JSONDecoder().decode(LocalTerminalMessage.self, from: encoded) == packet)
            #expect(encoded.count < LocalControlRequest.maximumEncodedBytes)
        }
    }
}
