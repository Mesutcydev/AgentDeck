//
//  DiagnosticsExportTests.swift
//  CompanionTests — AgentDeck
//
//  §12.2 diagnostics export: the document the exporter writes is
//  canonical, self-describing, and provably secret-free.
//

import Foundation
import Shared
import Testing
@testable import Companion

@MainActor
@Suite("§12.2 diagnostics export")
struct DiagnosticsExportTests {
    @Test("suggested file name is product-derived and timestamped")
    func fileName() {
        let name = DiagnosticsExporter.suggestedFileName(generatedAt: 1_752_793_200_000)
        #expect(name == "AgentDeck-Diagnostics-1752793200000.json")
    }

    @Test("export document is canonical JSON, parseable, and redacted")
    func document() throws {
        let report = DiagnosticsReport(
            generatedAt: 1_752_793_200_000,
            statusFields: [
                ("remoteAccessPaused", .bool(false)),
                ("activeSessions", .int(0))
            ],
            recentDiagnostics: [
                DiagnosticEntry(
                    timestamp: 1_752_793_200_000,
                    category: .session,
                    level: .info,
                    message: "companion started"
                )
            ]
        )
        let data = DiagnosticsExporter.document(for: report)
        let parsed = try JSONParser.parse(data)
        #expect(parsed.objectValue?["product"] == .string("AgentDeck"))
        let status = parsed.objectValue?["status"]?.objectValue
        #expect(status?["remoteAccessPaused"] == .bool(false))
        let entries = parsed.objectValue?["recentDiagnostics"]?.arrayValue
        #expect(entries?.count == 1)
        #expect(entries?.first?.objectValue?["message"] == .string("companion started"))
    }

    @Test("end-to-end: AppState report contains no planted secret")
    func endToEndRedaction() async throws {
        let defaults = try #require(UserDefaults(suiteName: "com.agentdeck.tests.\(UUID().uuidString)"))
        let state = AppState(
            defaults: defaults,
            loginItemManager: FakeLoginItemManager(),
            repository: nil,
            recorder: DiagnosticsRecorder()
        )
        await state.recorder.record(
            category: .approval, level: .info,
            message: "resolve api_key=sk-secretvalue123456"
        )
        let data = DiagnosticsExporter.document(for: await state.buildDiagnosticsReport())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sk-secretvalue123456"))
        #expect(text.contains("[REDACTED]"))
    }
}
