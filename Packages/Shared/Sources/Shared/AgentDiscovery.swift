//
//  AgentDiscovery.swift
//  Shared — AgentDeck
//
//  §12.3 executable discovery from safe explicit locations only. Never walks
//  the home directory unless `allowHomeDirectorySearch` is true. Probes only
//  catalog executables with known inspection arguments.
//

import Foundation

#if os(macOS)

public enum AgentDiscoveryError: Error, Equatable {
    case inspectionFailed(String)
}

/// §12.3 registry scanner. Injectable `ProcessRunner` keeps tests deterministic.
public struct AgentDiscoveryService {
    public typealias ProcessRunner = @Sendable (
        _ executable: String,
        _ arguments: [String]
    ) throws -> String

    private let configuration: AgentDiscoveryConfiguration
    private let fileManager: FileManager
    private let nowProvider: @Sendable () -> Int64
    private let runProcess: ProcessRunner

    /// Paths probed during the most recent `discover()` call (for audit/tests).
    public private(set) var lastProbedPaths: [String] = []

    public init(
        configuration: AgentDiscoveryConfiguration,
        fileManager: FileManager = .default,
        nowProvider: @escaping @Sendable () -> Int64 = { Date.unixMillisecondsNow },
        runProcess: @escaping ProcessRunner = AgentDiscoveryService.defaultProcessRunner
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.nowProvider = nowProvider
        self.runProcess = runProcess
    }

    /// Discovers installed catalog agents. Does not recurse directories.
    public mutating func discover(catalog: [AgentDescriptor] = AgentCatalog.all) -> [RegisteredAgent] {
        lastProbedPaths = []
        var found: [RegisteredAgent] = []
        let now = nowProvider()
        for descriptor in catalog {
            found.append(probe(descriptor: descriptor, now: now))
        }
        return found.sorted { $0.descriptor.displayName < $1.descriptor.displayName }
    }

    private mutating func probe(descriptor: AgentDescriptor, now: Int64) -> RegisteredAgent {
        for candidate in candidateExecutables(for: descriptor) {
            recordProbe(candidate)
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            guard let canonical = try? PathSafety.canonicalPath(for: URL(fileURLWithPath: candidate), fileManager: fileManager) else {
                continue
            }
            guard let version = inspectVersion(at: canonical, arguments: descriptor.versionArguments) else {
                return RegisteredAgent(
                    descriptor: descriptor,
                    installation: AgentInstallation(state: .broken(reason: "version inspection failed"), executablePath: canonical),
                    discoveredAt: now
                )
            }
            // Pin the accepted binary: digest + code-signing team become the
            // baseline the launch path verifies against (tamper detection).
            guard let fingerprint = try? ExecutableIntegrity.fingerprint(atPath: canonical) else {
                return RegisteredAgent(
                    descriptor: descriptor,
                    installation: AgentInstallation(state: .broken(reason: "integrity fingerprint failed"), executablePath: canonical),
                    discoveredAt: now
                )
            }
            ExecutableIntegrityRegistry.shared.record(fingerprint)
            return RegisteredAgent(
                descriptor: descriptor,
                installation: AgentInstallation(state: .installed(version: version), executablePath: canonical),
                codeSigningTeam: fingerprint.codeSigningTeam,
                discoveredAt: now
            )
        }
        return RegisteredAgent(
            descriptor: descriptor,
            installation: AgentInstallation(state: .notInstalled, executablePath: nil),
            discoveredAt: now
        )
    }

    private mutating func candidateExecutables(for descriptor: AgentDescriptor) -> [String] {
        var candidates = configuration.configuredExecutablePaths.filter { path in
            let basename = URL(fileURLWithPath: path).lastPathComponent
            return descriptor.executableNames.contains { name in
                basename == name || basename.hasSuffix("-\(name)")
            }
        }
        let directories = allowedBinDirectories()
        for directory in directories {
            for name in descriptor.executableNames {
                candidates.append((directory as NSString).appendingPathComponent(name))
            }
        }
        return candidates
    }

    private func allowedBinDirectories() -> [String] {
        var directories = configuration.systemBins + configuration.packageManagerBins
        directories.append(contentsOf: configuration.loginShellPathEntries.filter { entry in
            guard !entry.isEmpty else { return false }
            if configuration.allowHomeDirectorySearch { return true }
            return !isUnderHomeDirectory(entry)
        })
        return directories
    }

    private func isUnderHomeDirectory(_ path: String) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == home { return true }
        return normalized.hasPrefix(home + "/")
    }

    private mutating func recordProbe(_ path: String) {
        lastProbedPaths.append(path)
    }

    private func inspectVersion(at executable: String, arguments: [String]) -> String? {
        do {
            let output = try runProcess(executable, arguments).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { return nil }
            return String(output.prefix(120))
        } catch {
            return nil
        }
    }

    /// Default version probe: sanitized environment and a hard 5 s timeout —
    /// a hung binary fails honestly instead of blocking discovery forever.
    public static func defaultProcessRunner(executable: String, arguments: [String]) throws -> String {
        do {
            return try BoundedProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 5
            )
        } catch let failure as BoundedProcessRunner.Failure {
            throw AgentDiscoveryError.inspectionFailed("\(failure)")
        }
    }
}

#endif
