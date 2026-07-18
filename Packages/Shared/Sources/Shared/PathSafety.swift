//
//  PathSafety.swift
//  Shared — AgentDeck
//
//  §16 / §20.2 canonical-path and symlink-boundary checks for authorized
//  projects. Every stored project path is resolved before persistence; access
//  checks re-resolve and reject escapes.
//

import Foundation

public enum PathSafetyError: Error, Equatable {
    case notFound(String)
    case notDirectory(String)
    case canonicalizationFailed(String)
    case escapesProjectBoundary(root: String, candidate: String)
    case containsSymlinkComponent(path: String)
}

public enum PathSafety {
    /// Resolves `url` to an absolute path with symlinks eliminated.
    public static func canonicalPath(
        for url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        guard fileManager.fileExists(atPath: url.path) else {
            throw PathSafetyError.notFound(url.path)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw PathSafetyError.canonicalizationFailed(url.path)
        }
        return normalize(resolved.path)
    }

    /// Returns true when `candidate` is the project root or a path inside it
    /// after canonicalization (§20.2 project allowlist boundary).
    public static func isContained(in projectRoot: String, path candidate: String) -> Bool {
        let root = normalize(projectRoot)
        let path = normalize(candidate)
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }

    /// Rejects paths whose canonical form leaves the authorized project root
    /// or whose final component is a symlink (§20.2 symlink escape).
    public static func validateProjectPath(
        root: String,
        candidate: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let canonical = try canonicalPath(for: URL(fileURLWithPath: candidate), fileManager: fileManager)
        guard isContained(in: root, path: canonical) else {
            throw PathSafetyError.escapesProjectBoundary(root: root, candidate: canonical)
        }
        if pathHasSymlinkComponent(candidate, stoppingAt: root, fileManager: fileManager) {
            throw PathSafetyError.containsSymlinkComponent(path: candidate)
        }
        return canonical
    }

    /// True when any path component strictly below `stopAt` is a symlink.
    public static func pathHasSymlinkComponent(
        _ path: String,
        stoppingAt stopAt: String? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        var url = URL(fileURLWithPath: path)
        let stop = stopAt.map { normalize($0) }
        while !url.path.isEmpty && url.path != "/" {
            if let stop, normalize(url.path) == stop { break }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                return true
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
