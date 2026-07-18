//
//  DiagnosticsRecorderTests.swift
//  SharedTests — AgentDeck
//

import Foundation
import Testing
@testable import Shared

@Suite("diagnostics recorder and report")
struct DiagnosticsRecorderTests {
    @Test("entries are redacted at record time")
    func redactionAtRecord() async {
        let recorder = DiagnosticsRecorder()
        await recorder.record(
            category: .session, level: .info,
            message: "launched with Bearer abcdef1234567890 and password=hunter2",
            timestamp: 1_000
        )
        let entries = await recorder.recentEntries()
        #expect(entries.count == 1)
        #expect(!entries[0].message.contains("abcdef1234567890"))
        #expect(!entries[0].message.contains("hunter2"))
        #expect(entries[0].message.contains("launched with"))
    }

    @Test("the buffer is bounded, oldest dropped")
    func boundedBuffer() async {
        let recorder = DiagnosticsRecorder(capacity: 3)
        for index in 1...5 {
            await recorder.record(category: .wire, level: .debug, message: "m\(index)", timestamp: Int64(index))
        }
        #expect(await recorder.count == 3)
        let messages = await recorder.recentEntries().map(\.message)
        #expect(messages == ["m3", "m4", "m5"])
        let limited = await recorder.recentEntries(limit: 2).map(\.message)
        #expect(limited == ["m4", "m5"])
    }

    @Test("report renders canonical JSON with product name and no secrets")
    func reportRendering() async throws {
        let recorder = DiagnosticsRecorder()
        await recorder.record(
            category: .approval, level: .notice,
            message: "resolve api_key=sk-secretvalue123456", timestamp: 2_000
        )
        let report = DiagnosticsReport(
            generatedAt: 1_752_793_200_000,
            statusFields: [
                ("paused", .bool(false)),
                ("activeSessions", .int(0))
            ],
            recentDiagnostics: await recorder.recentEntries()
        )
        let canonical = String(decoding: report.canonicalBytes(), as: UTF8.self)
        #expect(canonical.contains("\"product\":\"AgentDeck\""))
        #expect(canonical.contains("\"generatedAt\":1752793200000"))
        #expect(canonical.contains("\"paused\":false"))
        #expect(!canonical.contains("sk-secretvalue123456"))
        #expect(canonical.contains("[REDACTED]"))
        // Round-trips through the strict parser.
        #expect(try JSONParser.parse(canonical).objectValue?["product"] == .string("AgentDeck"))
    }
}
