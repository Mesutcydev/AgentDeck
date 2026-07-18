//
//  DiagnosticsExporter.swift
//  Companion — AgentDeck
//
//  §12.2 diagnostics export: a redacted bundle (status snapshot + recent
//  diagnostics from the Phase 1 recorder, scrubbed by the Phase 1
//  Redactor) written to a user-chosen location via NSSavePanel. The
//  report-building path is headless-testable; only the panel is UI.
//

import AppKit
import Foundation
import Shared

@MainActor
enum DiagnosticsExporter {
    /// Builds the redacted report and asks the user where to save it.
    static func export(from state: AppState) async {
        let report = await state.buildDiagnosticsReport()
        do {
            try await presentSavePanel(for: report)
            Log.logger(.session).info("diagnostics exported")
            await state.recorder.record(category: .session, level: .info, message: "diagnostics exported")
        } catch DiagnosticsExportError.userCancelled {
            // User dismissed the panel — not an error.
        } catch {
            Log.logger(.session).error("diagnostics export failed: \(error.localizedDescription, privacy: .public)")
            await state.recorder.record(
                category: .session, level: .error,
                message: "diagnostics export failed: \(error.localizedDescription)"
            )
        }
    }

    /// Builds the canonical document without any UI (unit-tested path).
    static func document(for report: DiagnosticsReport) -> Data {
        report.canonicalBytes()
    }

    private static func presentSavePanel(for report: DiagnosticsReport) async throws {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = suggestedFileName(generatedAt: report.generatedAt)
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            throw DiagnosticsExportError.userCancelled
        }
        try document(for: report).write(to: url, options: .atomic)
    }

    static func suggestedFileName(generatedAt: Int64) -> String {
        "\(ProductNaming.name)-Diagnostics-\(generatedAt).json"
    }
}

enum DiagnosticsExportError: Error {
    case userCancelled
}
