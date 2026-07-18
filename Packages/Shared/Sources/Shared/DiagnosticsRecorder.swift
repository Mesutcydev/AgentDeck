//
//  DiagnosticsRecorder.swift
//  Shared — AgentDeck
//
//  §12.2/§21 diagnostics: a bounded in-process mirror of noteworthy log
//  lines, captured WITH redaction at record time (Constitution #8). The
//  companion assembles a DiagnosticsReport from this recorder plus its
//  status model; the report is what the diagnostics export writes to a
//  user-chosen location. Actor per §25; injected, not global.
//

import Foundation

public enum DiagnosticLevel: String, Sendable, CaseIterable, Codable, JSONValueConvertible {
    case debug
    case info
    case notice
    case warning
    case error
    case fault
}

/// One mirrored diagnostics line. The message is redacted at record time.
public struct DiagnosticEntry: Sendable, Equatable {
    public let timestamp: Int64
    public let category: LogCategory
    public let level: DiagnosticLevel
    public let message: String

    public init(timestamp: Int64, category: LogCategory, level: DiagnosticLevel, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
    }
}

extension LogCategory: JSONValueConvertible {}

extension DiagnosticEntry: JSONValueConvertible {
    public init(jsonValue: JSONValue) throws {
        self.init(
            timestamp: try jsonValue.intField("ts"),
            category: try jsonValue.nestedField("category", as: LogCategory.self),
            level: try jsonValue.nestedField("level", as: DiagnosticLevel.self),
            message: try jsonValue.stringField("message")
        )
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("ts", .int(timestamp)),
            ("category", category.toJSONValue()),
            ("level", level.toJSONValue()),
            ("message", .string(message))
        ])
    }
}

/// Bounded rolling buffer of recent diagnostic entries (oldest dropped).
public actor DiagnosticsRecorder {
    public static let defaultCapacity = 500

    private var entries: [DiagnosticEntry] = []
    private let capacity: Int

    public init(capacity: Int = DiagnosticsRecorder.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Records a line. The message is scrubbed by Redactor BEFORE it is
    /// stored — the buffer can never hold a secret.
    public func record(
        category: LogCategory,
        level: DiagnosticLevel,
        message: String,
        timestamp: Int64 = Date.unixMillisecondsNow
    ) {
        entries.append(DiagnosticEntry(
            timestamp: timestamp,
            category: category,
            level: level,
            message: Redactor.redact(message)
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func recentEntries(limit: Int? = nil) -> [DiagnosticEntry] {
        guard let limit, entries.count > limit else { return entries }
        return Array(entries.suffix(limit))
    }

    public var count: Int { entries.count }
}

/// A redacted, self-describing diagnostics document (§12.2 export). The
/// caller supplies the status fields; entries come from the recorder.
public struct DiagnosticsReport: Sendable {
    public let generatedAt: Int64
    /// Caller-supplied status (paired-device count, pause state, etc.).
    public let statusFields: [(String, JSONValue)]
    public let recentDiagnostics: [DiagnosticEntry]

    public init(
        generatedAt: Int64,
        statusFields: [(String, JSONValue)],
        recentDiagnostics: [DiagnosticEntry]
    ) {
        self.generatedAt = generatedAt
        self.statusFields = statusFields
        self.recentDiagnostics = recentDiagnostics
    }

    public func toJSONValue() -> JSONValue {
        .object([
            ("generatedAt", .int(generatedAt)),
            ("product", .string(ProductNaming.name)),
            ("status", .object(statusFields)),
            ("recentDiagnostics", .array(recentDiagnostics.map { $0.toJSONValue() }))
        ])
    }

    /// Canonical JSON bytes — what the export writes to disk.
    public func canonicalBytes() -> Data {
        toJSONValue().canonicalBytes()
    }
}
