import Foundation
import Shared

actor LocalTerminalBroker {
    typealias Sink = @Sendable (Data) -> Void
    private var sinks: [SessionID: [UUID: Sink]] = [:]

    func subscribe(sessionID: SessionID, sink: @escaping Sink) -> UUID {
        let token = UUID()
        sinks[sessionID, default: [:]][token] = sink
        return token
    }

    func unsubscribe(sessionID: SessionID, token: UUID) {
        sinks[sessionID]?[token] = nil
        if sinks[sessionID]?.isEmpty == true { sinks[sessionID] = nil }
    }

    func publish(sessionID: SessionID, data: Data) {
        guard let sessionSinks = sinks[sessionID] else { return }
        for sink in sessionSinks.values { sink(data) }
    }
}
