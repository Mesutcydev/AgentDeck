//
//  ClaudeHookManager.swift
//  Shared — AgentDeck
//
//  §29 Phase 7: installs a narrowly-scoped AgentDeck-managed Claude Code
//  PreToolUse hook with explicit approval only, keeps a backup of the user's
//  settings, merges non-destructively, and supports removal/restoration.
//

import Foundation

#if os(macOS)

public enum ClaudeHookManagerError: Error, Equatable {
    case explicitApprovalRequired
    case invalidSettingsRoot(String)
    case invalidSettingsFile(String)
    case backupMissing
}

public struct ClaudeHookManagerConfiguration: Sendable, Equatable {
    public let claudeDirectoryPath: String

    public init(
        claudeDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .path
    ) {
        self.claudeDirectoryPath = claudeDirectoryPath
    }
}

public actor ClaudeHookManager {
    private enum Constants {
        static let marker = "AGENTDECK_CLAUDE_HOOK_MARKER=phase7"
        static let managedDirectoryName = "agentdeck"
        static let backupFileName = "settings.backup.json"
        static let manifestFileName = "settings.backup.manifest.json"
        static let defaultTimeoutSeconds = "300"
    }

    private struct BackupManifest: Codable, Equatable {
        let settingsExisted: Bool
    }

    private let configuration: ClaudeHookManagerConfiguration
    private let fileManager: FileManager

    public init(
        configuration: ClaudeHookManagerConfiguration = ClaudeHookManagerConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func installHooks(explicitApprovalGranted: Bool) throws {
        guard explicitApprovalGranted else {
            throw ClaudeHookManagerError.explicitApprovalRequired
        }

        try ensureClaudeDirectory()
        try createBackupIfNeeded()

        var root = try loadSettingsObject()
        root = mergeManagedHook(into: root)
        try writeSettingsObject(root)
    }

    public func removeHooks() throws {
        let current = try loadSettingsObject()
        let stripped = removeManagedHook(from: current)
        try restoreOriginalIfPossible(or: stripped)
        try deleteBackupArtifactsIfPresent()
    }

    public func restoreBackup() throws {
        let manifest = try loadBackupManifest()
        if manifest.settingsExisted {
            try ensureClaudeDirectory()
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw ClaudeHookManagerError.backupMissing
            }
            if fileManager.fileExists(atPath: settingsURL.path) {
                try fileManager.removeItem(at: settingsURL)
            }
            try fileManager.copyItem(at: backupURL, to: settingsURL)
        } else if fileManager.fileExists(atPath: settingsURL.path) {
            try fileManager.removeItem(at: settingsURL)
        }
        try deleteBackupArtifactsIfPresent()
    }

    public func managedHookIsInstalled() throws -> Bool {
        containsManagedHook(in: try loadSettingsObject())
    }

    private var claudeDirectoryURL: URL {
        URL(fileURLWithPath: configuration.claudeDirectoryPath, isDirectory: true)
    }

    private var settingsURL: URL {
        claudeDirectoryURL.appendingPathComponent("settings.json")
    }

    private var managedDirectoryURL: URL {
        claudeDirectoryURL.appendingPathComponent(Constants.managedDirectoryName, isDirectory: true)
    }

    private var backupURL: URL {
        managedDirectoryURL.appendingPathComponent(Constants.backupFileName)
    }

    private var manifestURL: URL {
        managedDirectoryURL.appendingPathComponent(Constants.manifestFileName)
    }

    private func ensureClaudeDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: claudeDirectoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ClaudeHookManagerError.invalidSettingsRoot(claudeDirectoryURL.path)
            }
            return
        }
        try fileManager.createDirectory(at: claudeDirectoryURL, withIntermediateDirectories: true)
    }

    private func ensureManagedDirectory() throws {
        try fileManager.createDirectory(at: managedDirectoryURL, withIntermediateDirectories: true)
    }

    private func createBackupIfNeeded() throws {
        guard !fileManager.fileExists(atPath: manifestURL.path) else { return }
        try ensureManagedDirectory()

        let settingsExisted = fileManager.fileExists(atPath: settingsURL.path)
        if settingsExisted {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: settingsURL, to: backupURL)
        }

        let manifest = BackupManifest(settingsExisted: settingsExisted)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func loadBackupManifest() throws -> BackupManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ClaudeHookManagerError.backupMissing
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(BackupManifest.self, from: data)
    }

    private func loadSettingsObject() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw ClaudeHookManagerError.invalidSettingsFile(settingsURL.path)
        }
        return root
    }

    private func loadBackupObjectIfPresent() throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
        let data = try Data(contentsOf: backupURL)
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any]
    }

    private func writeSettingsObject(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        var output = data
        if output.last != 0x0A {
            output.append(0x0A)
        }
        try output.write(to: settingsURL, options: .atomic)
    }

    private func mergeManagedHook(into root: [String: Any]) -> [String: Any] {
        var nextRoot = root
        var hooks = nextRoot["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []

        guard !preToolUse.contains(where: groupContainsManagedHook) else {
            nextRoot["hooks"] = hooks
            return nextRoot
        }

        preToolUse.append([
            "matcher": ".*",
            "hooks": [[
                "type": "command",
                "command": Self.managedCommand()
            ]]
        ])
        hooks["PreToolUse"] = preToolUse
        nextRoot["hooks"] = hooks
        return nextRoot
    }

    private func removeManagedHook(from root: [String: Any]) -> [String: Any] {
        var nextRoot = root
        guard var hooks = nextRoot["hooks"] as? [String: Any] else { return nextRoot }
        if let groups = hooks["PreToolUse"] as? [[String: Any]] {
            let filteredGroups = groups.compactMap(removeManagedHooks(from:))
            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: "PreToolUse")
            } else {
                hooks["PreToolUse"] = filteredGroups
            }
        }

        if hooks.isEmpty {
            nextRoot.removeValue(forKey: "hooks")
        } else {
            nextRoot["hooks"] = hooks
        }
        return nextRoot
    }

    private func removeManagedHooks(from group: [String: Any]) -> [String: Any]? {
        var nextGroup = group
        let hooks = group["hooks"] as? [[String: Any]] ?? []
        let filteredHooks = hooks.filter { hook in
            guard let command = hook["command"] as? String else { return true }
            return !command.contains(Constants.marker)
        }
        guard !filteredHooks.isEmpty else { return nil }
        nextGroup["hooks"] = filteredHooks
        return nextGroup
    }

    private func containsManagedHook(in root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        return groups.contains(where: groupContainsManagedHook)
    }

    private func groupContainsManagedHook(_ group: [String: Any]) -> Bool {
        let hooks = group["hooks"] as? [[String: Any]] ?? []
        return hooks.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains(Constants.marker)
        }
    }

    private func restoreOriginalIfPossible(or stripped: [String: Any]) throws {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            if stripped.isEmpty {
                if fileManager.fileExists(atPath: settingsURL.path) {
                    try fileManager.removeItem(at: settingsURL)
                }
            } else {
                try ensureClaudeDirectory()
                try writeSettingsObject(stripped)
            }
            return
        }

        let manifest = try loadBackupManifest()
        let restoredOriginal = try loadBackupObjectIfPresent()
        if manifest.settingsExisted,
           let restoredOriginal,
           try jsonData(for: restoredOriginal) == jsonData(for: stripped) {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try fileManager.removeItem(at: settingsURL)
            }
            try fileManager.copyItem(at: backupURL, to: settingsURL)
            return
        }

        if !manifest.settingsExisted && stripped.isEmpty {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try fileManager.removeItem(at: settingsURL)
            }
            return
        }

        if stripped.isEmpty {
            if fileManager.fileExists(atPath: settingsURL.path) {
                try fileManager.removeItem(at: settingsURL)
            }
            return
        }

        try ensureClaudeDirectory()
        try writeSettingsObject(stripped)
    }

    private func jsonData(for object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func deleteBackupArtifactsIfPresent() throws {
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }
        if fileManager.fileExists(atPath: managedDirectoryURL.path),
           (try? fileManager.contentsOfDirectory(atPath: managedDirectoryURL.path).isEmpty) == true {
            try? fileManager.removeItem(at: managedDirectoryURL)
        }
    }

    /// Managed hook command. The Python payload is base64-encoded and passed
    /// as an argv entry: the base64 alphabet contains no quotes, so neither
    /// the single-quoted `-c` wrapper nor the payload argument can be broken
    /// by an apostrophe in the script — the previous `python3 -c '<script>'`
    /// embedding was one apostrophe away from silent breakage.
    private static func managedCommand() -> String {
        let script = """
import json, os, pathlib, sys, time, uuid
payload = json.load(sys.stdin)
directory = os.environ.get("AGENTDECK_CLAUDE_HOOK_DIR")
timeout = float(os.environ.get("AGENTDECK_CLAUDE_HOOK_TIMEOUT_SECONDS", "\(Constants.defaultTimeoutSeconds)"))
if not directory:
    sys.exit(0)
base = pathlib.Path(directory)
base.mkdir(parents=True, exist_ok=True)
request_id = str(uuid.uuid4())
request_path = base / ("request-" + request_id + ".json")
response_path = base / ("response-" + request_id + ".json")
request = {
    "request_id": request_id,
    "session_id": payload.get("session_id"),
    "cwd": payload.get("cwd"),
    "hook_event_name": payload.get("hook_event_name"),
    "tool_name": payload.get("tool_name"),
    "tool_input": payload.get("tool_input"),
}
# Approval request files carry tool-call detail: owner-only from creation.
fd = os.open(request_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(request, separators=(",", ":")))
decision = "deny"
message = "AgentDeck approval timed out"
deadline = time.time() + timeout
while time.time() < deadline:
    if response_path.exists():
        response = json.loads(response_path.read_text(encoding="utf-8"))
        decision = response.get("decision", "deny")
        message = response.get("message", "Resolved by AgentDeck")
        break
    time.sleep(0.05)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow" if decision == "allow" else "deny",
        "permissionDecisionReason": message,
    }
}, separators=(",", ":")))
"""
        let payload = Data(script.utf8).base64EncodedString()
        let decoder = "import base64,sys;exec(base64.b64decode(sys.argv[1]).decode('utf-8'))"
        return "\(Constants.marker) /usr/bin/env python3 -c \"\(decoder)\" '\(payload)'"
    }
}

#endif
