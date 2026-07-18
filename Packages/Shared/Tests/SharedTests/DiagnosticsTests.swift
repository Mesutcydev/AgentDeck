//
//  DiagnosticsTests.swift
//  SharedTests — AgentDeck
//
//  Smoke + behavior tests for the logging abstraction and the §23
//  metrics scaffolding.
//

import Foundation
import Testing
@testable import Shared

@Suite("logging abstraction")
struct LoggingTests {
    @Test("loggers construct per category and log at all levels without crashing")
    func smoke() {
        for category in LogCategory.allCases {
            let log = Log.logger(category)
            log.debug("debug \(1, privacy: .public)")
            log.info("info \("value", privacy: .public)")
            log.notice("notice")
            log.warning("warning \(UUID().uuidString, privacy: .private)")
            log.error("error")
        }
        #expect(LogCategory.allCases.count == 7)
    }

    @Test("subsystem derives from the product name (SPEC §2)")
    func subsystemDerived() {
        #expect(ProductNaming.name == "AgentDeck")
        #expect(ProductNaming.logSubsystem == "com.agentdeck.diagnostics")
        #expect(ProductNaming.wireNamespace == "agentdeck")
    }
}

@Suite("§23 metrics scaffolding")
struct MetricsTests {
    @Test("counters increment, accumulate, snapshot, and reset")
    func counters() async {
        let counter = MetricsCounter()
        #expect(await counter.value(of: .framesSent) == 0)
        await counter.increment(.framesSent)
        await counter.increment(.framesSent)
        await counter.increment(.frameBytesSent, by: 512)
        #expect(await counter.value(of: .framesSent) == 2)
        #expect(await counter.value(of: .frameBytesSent) == 512)
        let snapshot = await counter.snapshot()
        #expect(snapshot[.framesSent] == 2)
        #expect(snapshot[.framesReceived] == nil)
        await counter.reset()
        #expect(await counter.value(of: .framesSent) == 0)
    }

    @Test("signposter wraps begin/end/event and measure helpers")
    func signposter() async throws {
        let signposter = DeckSignposter(category: "test")
        let state = signposter.beginInterval("manual")
        signposter.endInterval("manual", state)
        signposter.emitEvent("event")

        let syncResult = signposter.measure("sync-op") { 40 + 2 }
        #expect(syncResult == 42)

        let asyncResult = try await signposter.measure("async-op") {
            try await Task.sleep(for: .milliseconds(1))
            return "done"
        }
        #expect(asyncResult == "done")

        let poi = DeckSignposter(category: "ignored", pointsOfInterest: true)
        poi.emitEvent("poi-event")
    }

    @Test("all standard metric names are distinct")
    func metricNamesDistinct() {
        let names = MetricName.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }
}
