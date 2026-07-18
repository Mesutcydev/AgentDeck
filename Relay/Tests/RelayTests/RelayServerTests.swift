import CryptoKit
import Foundation
import RelayCore
import Shared
import Testing

@Suite("§14.3 relay HTTP server")
struct RelayServerTests {
    @Test("relay accepts signed notify requests and records simulated APNs delivery")
    func acceptsSignedRequest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            signingPublicKey: privateKey.publicKey
        ), outbox: outbox)
        defer { try? channel.close().wait() }

        let port = channel.localAddress?.port ?? 0
        var request = RelayNotifyRequest(
            destinationToken: try #require(PushDestinationToken("sim-token")),
            eventType: .sessionCompleted,
            sessionID: SessionID.random(),
            projectAlias: "Demo",
            notificationText: "Done.",
            expiration: Date.unixMillisecondsNow + 120_000
        )
        try RelaySigning.sign(&request, privateKey: privateKey)

        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/notify")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try request.toJSONValue().canonicalBytes()
        let (_, response) = try syncData(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 202)
        #expect(outbox.deliveries.count == 1)
    }

    @Test("relay rejects forbidden terminal output fields")
    func rejectsForbiddenFields() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let outbox = SimulatedAPNsOutbox()
        let channel = try RelayHTTPServer.start(configuration: .init(
            host: "127.0.0.1",
            port: 0,
            signingPublicKey: privateKey.publicKey
        ), outbox: outbox)
        defer { try? channel.close().wait() }

        let port = channel.localAddress?.port ?? 0
        let body = """
        {"payloadV":1,"destinationToken":"sim","eventType":"session_completed","sessionID":"\(SessionID.random().wireString)","notificationText":"ok","expiration":\(Date.unixMillisecondsNow + 120_000),"terminalOutput":"secret"}
        """
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/notify")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Data(body.utf8)
        let (_, response) = try syncData(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode
        #expect(status == 400)
        #expect(outbox.deliveries.isEmpty)
    }
}

func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
    final class ResultBox: @unchecked Sendable {
        var value: Result<(Data, URLResponse), Error>?
    }
    let box = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            box.value = .failure(error)
        } else if let data, let response {
            box.value = .success((data, response))
        } else {
            box.value = .failure(URLError(.badServerResponse))
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return try box.value!.get()
}
