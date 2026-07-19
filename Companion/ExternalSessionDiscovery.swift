import Foundation
import Shared

/// Local-only, metadata-only discovery. Transcript bodies are never loaded
/// into AgentDeck; only identifiers, working directories, versions and dates.
struct ExternalSessionDiscovery {
    private let fileManager: FileManager
    private let home: URL

    init(fileManager: FileManager = .default, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.home = home
    }

    func discover(limit: Int = 50) -> [ExternalSessionDescriptor] {
        let capped = min(100, max(1, limit))
        return (discoverClaude() + discoverCodex())
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(capped)
            .map { $0 }
    }

    private func discoverClaude() -> [ExternalSessionDescriptor] {
        let roots = [
            home.appendingPathComponent(".claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude/transcripts", isDirectory: true)
        ]
        var result: [ExternalSessionDescriptor] = []
        var seen = Set<String>()
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let metadata = metadataPrefix(at: url),
                      let identifier = metadata.string("sessionId") ?? identifierFromFilename(url),
                      seen.insert(identifier).inserted else { continue }
                result.append(ExternalSessionDescriptor(
                    providerID: "com.anthropic.claude-code",
                    externalSessionID: identifier,
                    projectPath: metadata.string("cwd"),
                    updatedAt: modificationDate(url),
                    compatibilityVersion: metadata.string("version"),
                    processState: processState(providerToken: "claude", externalID: identifier),
                    canResume: true
                ))
            }
        }
        return result
    }

    private func discoverCodex() -> [ExternalSessionDescriptor] {
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: index) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2 * 1024 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let bytes = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let identifier = object["id"] as? String ?? object["thread_id"] as? String else { return nil }
            let updated = (object["updated_at"] as? String).flatMap(Self.iso8601Milliseconds) ?? modificationDate(index)
            return ExternalSessionDescriptor(
                providerID: "com.openai.codex",
                externalSessionID: identifier,
                projectPath: object["cwd"] as? String,
                updatedAt: updated,
                compatibilityVersion: object["version"] as? String,
                processState: processState(providerToken: "codex", externalID: identifier),
                canResume: true
            )
        }
    }

    /// Reads at most 64 KiB and only retains known metadata keys.
    private func metadataPrefix(at url: URL) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n").prefix(20) {
            guard let bytes = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
            for key in ["sessionId", "cwd", "version"] where values[key] == nil {
                values[key] = object[key] as? String
            }
        }
        return Metadata(values: values)
    }

    private func identifierFromFilename(_ url: URL) -> String? {
        let value = url.deletingPathExtension().lastPathComponent
        return value.isEmpty ? nil : value
    }

    private func modificationDate(_ url: URL) -> Int64 {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func processState(providerToken: String, externalID: String) -> ExternalSessionProcessState {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { return .unknown }
            return text.split(separator: "\n").contains { line in
                line.localizedCaseInsensitiveContains(providerToken) && line.contains(externalID)
            } ? .active : .inactive
        } catch {
            return .unknown
        }
    }

    private static func iso8601Milliseconds(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private struct Metadata {
        var values: [String: String]
        func string(_ key: String) -> String? { values[key] }
    }
}
