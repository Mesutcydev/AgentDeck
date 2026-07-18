//
//  DirectoryDiffGenerator.swift
//  Shared — AgentDeck
//
//  Phase 9 diff generation on macOS using `git diff --no-index` with process
//  arguments only — never shell interpolation — so hostile filenames cannot
//  inject commands.
//

import Foundation

public enum DirectoryDiffError: Error, Equatable {
    case unsupportedPlatform
    case ioFailed(String)
    case toolFailed(String)
}

public enum DirectoryDiffGenerator {
    public static func diffDirectories(
        oldRoot: String,
        newRoot: String,
        fileManager: FileManager = .default
    ) throws -> UnifiedDiffDocument {
#if os(macOS)
        let oldURL = URL(fileURLWithPath: oldRoot, isDirectory: true).standardizedFileURL
        let newURL = URL(fileURLWithPath: newRoot, isDirectory: true).standardizedFileURL
        let paths = try Set(collectRelativePaths(root: oldURL, fileManager: fileManager))
            .union(collectRelativePaths(root: newURL, fileManager: fileManager))
            .sorted()

        let placeholderURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("agentdeck-empty-\(UUID().uuidString)")
        try Data().write(to: placeholderURL, options: .atomic)
        defer { try? fileManager.removeItem(at: placeholderURL) }

        var chunks: [String] = []
        for relativePath in paths {
            let oldFile = oldURL.appendingPathComponent(relativePath)
            let newFile = newURL.appendingPathComponent(relativePath)
            let oldExists = fileManager.fileExists(atPath: oldFile.path)
            let newExists = fileManager.fileExists(atPath: newFile.path)
            guard oldExists || newExists else { continue }
            if oldExists, newExists,
               let oldData = try? Data(contentsOf: oldFile),
               let newData = try? Data(contentsOf: newFile),
               oldData == newData {
                continue
            }
            let diff = try runUnifiedDiff(
                oldPath: oldExists ? oldFile.path : placeholderURL.path,
                newPath: newExists ? newFile.path : placeholderURL.path,
                relativePath: relativePath,
                status: oldExists ? (newExists ? .modified : .deleted) : .added
            )
            if !diff.isEmpty {
                chunks.append(diff)
            }
        }

        return try UnifiedDiffParser.parse(chunks.joined(separator: "\n"))
#else
        throw DirectoryDiffError.unsupportedPlatform
#endif
    }

#if os(macOS)
    private static func collectRelativePaths(
        root: URL,
        fileManager: FileManager
    ) throws -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DirectoryDiffError.ioFailed("unable to enumerate \(root.path)")
        }
        var paths: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let standardizedRoot = root.standardizedFileURL.path
            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(standardizedRoot + "/") else {
                throw DirectoryDiffError.ioFailed("path escaped diff root: \(standardizedPath)")
            }
            let relativePath = String(standardizedPath.dropFirst(standardizedRoot.count + 1))
            paths.append(relativePath)
        }
        return paths
    }

    private static func runUnifiedDiff(
        oldPath: String,
        newPath: String,
        relativePath: String,
        status: ChangedFileStatus
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = [
            "-u",
            "--label", "a/\(relativePath)",
            "--label", "b/\(relativePath)",
            oldPath,
            newPath
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw DirectoryDiffError.toolFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw DirectoryDiffError.toolFailed(text)
        }
        guard !text.isEmpty else { return "" }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if status == .added, !lines.isEmpty {
            lines[0] = "--- /dev/null"
        } else if status == .deleted, lines.count > 1 {
            lines[1] = "+++ /dev/null"
        }
        var prefix = ["diff --git a/\(relativePath) b/\(relativePath)"]
        switch status {
        case .added:
            prefix.append("new file mode 100644")
        case .deleted:
            prefix.append("deleted file mode 100644")
        case .modified, .renamed:
            break
        }
        prefix.append(contentsOf: lines)
        return prefix.joined(separator: "\n")
    }
#endif
}
