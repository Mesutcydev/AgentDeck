//
//  UnifiedDiff.swift
//  Shared — AgentDeck
//
//  Phase 9 diff models and a strict parser for unified diff output. The app
//  UI consumes these value types; generation can stay platform-specific.
//

import Foundation

public enum ChangedFileStatus: String, Sendable, CaseIterable, Codable {
    case added
    case modified
    case deleted
    case renamed
}

public struct ChangedFileSummary: Sendable, Equatable, Identifiable {
    public let path: String
    public let oldPath: String?
    public let status: ChangedFileStatus
    public let additions: Int64
    public let deletions: Int64

    public init(
        path: String,
        oldPath: String? = nil,
        status: ChangedFileStatus,
        additions: Int64,
        deletions: Int64
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    public var id: String { path }
}

public enum UnifiedDiffLineKind: String, Sendable, CaseIterable, Codable {
    case context
    case addition
    case deletion
}

public struct UnifiedDiffLine: Sendable, Equatable {
    public let kind: UnifiedDiffLineKind
    public let text: String

    public init(kind: UnifiedDiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct UnifiedDiffHunk: Sendable, Equatable {
    public let oldStart: Int64
    public let oldCount: Int64
    public let newStart: Int64
    public let newCount: Int64
    public let header: String?
    public let lines: [UnifiedDiffLine]

    public init(
        oldStart: Int64,
        oldCount: Int64,
        newStart: Int64,
        newCount: Int64,
        header: String?,
        lines: [UnifiedDiffLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

public struct UnifiedDiffFile: Sendable, Equatable, Identifiable {
    public let changedFile: ChangedFileSummary
    public let hunks: [UnifiedDiffHunk]

    public init(changedFile: ChangedFileSummary, hunks: [UnifiedDiffHunk]) {
        self.changedFile = changedFile
        self.hunks = hunks
    }

    public var id: String { changedFile.id }
}

public struct UnifiedDiffDocument: Sendable, Equatable {
    public let files: [UnifiedDiffFile]
    public let rawText: String

    public init(files: [UnifiedDiffFile], rawText: String) {
        self.files = files
        self.rawText = rawText
    }
}

public enum UnifiedDiffError: Error, Equatable {
    case invalidDiffHeader(String)
    case invalidHunkHeader(String)
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String) throws -> UnifiedDiffDocument {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var files: [UnifiedDiffFile] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("diff --git ") else {
                index += 1
                continue
            }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4 else {
                throw UnifiedDiffError.invalidDiffHeader(line)
            }
            var oldPath = stripDiffPathPrefix(parts[2])
            var path = stripDiffPathPrefix(parts[3])
            var status: ChangedFileStatus = .modified
            var hunks: [UnifiedDiffHunk] = []
            var additions: Int64 = 0
            var deletions: Int64 = 0
            index += 1

            while index < lines.count, !lines[index].hasPrefix("diff --git ") {
                let current = lines[index]
                if current.hasPrefix("new file mode ") {
                    status = .added
                } else if current.hasPrefix("deleted file mode ") {
                    status = .deleted
                } else if current.hasPrefix("rename from ") {
                    status = .renamed
                    oldPath = String(current.dropFirst("rename from ".count))
                } else if current.hasPrefix("rename to ") {
                    path = String(current.dropFirst("rename to ".count))
                } else if current.hasPrefix("--- ") {
                    let parsed = String(current.dropFirst(4))
                    if parsed == "/dev/null" {
                        status = .added
                    } else {
                        oldPath = stripDiffPathPrefix(parsed)
                    }
                } else if current.hasPrefix("+++ ") {
                    let parsed = String(current.dropFirst(4))
                    if parsed == "/dev/null" {
                        status = .deleted
                    } else {
                        path = stripDiffPathPrefix(parsed)
                    }
                } else if current.hasPrefix("@@ ") {
                    let (hunk, nextIndex, hunkAdditions, hunkDeletions) = try parseHunk(
                        startingAt: index,
                        in: lines
                    )
                    hunks.append(hunk)
                    additions += hunkAdditions
                    deletions += hunkDeletions
                    index = nextIndex
                    continue
                }
                index += 1
            }

            let summary = ChangedFileSummary(
                path: path,
                oldPath: oldPath == path ? nil : oldPath,
                status: status,
                additions: additions,
                deletions: deletions
            )
            files.append(UnifiedDiffFile(changedFile: summary, hunks: hunks))
        }

        return UnifiedDiffDocument(files: files, rawText: text)
    }

    private static func parseHunk(
        startingAt index: Int,
        in lines: [String]
    ) throws -> (UnifiedDiffHunk, Int, Int64, Int64) {
        let headerLine = lines[index]
        let pattern = #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?: ?(.*))?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(headerLine.startIndex..<headerLine.endIndex, in: headerLine)
        guard let match = regex.firstMatch(in: headerLine, options: [], range: range) else {
            throw UnifiedDiffError.invalidHunkHeader(headerLine)
        }

        func value(at position: Int, default defaultValue: Int64) throws -> Int64 {
            let range = match.range(at: position)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: headerLine) else {
                return defaultValue
            }
            return Int64(headerLine[swiftRange]) ?? defaultValue
        }

        let oldStart = try value(at: 1, default: 0)
        let oldCount = try value(at: 2, default: 1)
        let newStart = try value(at: 3, default: 0)
        let newCount = try value(at: 4, default: 1)
        let header = match.range(at: 5).location == NSNotFound
            ? nil
            : Range(match.range(at: 5), in: headerLine).map { String(headerLine[$0]) }

        var nextIndex = index + 1
        var linesInHunk: [UnifiedDiffLine] = []
        var additions: Int64 = 0
        var deletions: Int64 = 0

        while nextIndex < lines.count {
            let line = lines[nextIndex]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") {
                break
            }
            if line == "\\ No newline at end of file" {
                nextIndex += 1
                continue
            }
            if let prefix = line.first {
                switch prefix {
                case "+":
                    linesInHunk.append(UnifiedDiffLine(kind: .addition, text: String(line.dropFirst())))
                    additions += 1
                case "-":
                    linesInHunk.append(UnifiedDiffLine(kind: .deletion, text: String(line.dropFirst())))
                    deletions += 1
                case " ":
                    linesInHunk.append(UnifiedDiffLine(kind: .context, text: String(line.dropFirst())))
                default:
                    break
                }
            }
            nextIndex += 1
        }

        return (
            UnifiedDiffHunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                header: header,
                lines: linesInHunk
            ),
            nextIndex,
            additions,
            deletions
        )
    }

    private static func stripDiffPathPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}
